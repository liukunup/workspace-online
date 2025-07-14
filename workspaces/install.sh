#!/bin/bash

# 确保出错时立即退出
set -euo pipefail

# =============================================
# 标准部署脚本
# 功能：xxx
# 适用：Linux 系统
# 版本: 0.0.1
# =============================================

# ------------ 常量定义区 (不要修改) ------------
readonly SCRIPT_VERSION="0.0.1"
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_FILE="${SCRIPT_NAME%.*}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"

# ------------ 配置区 (用户可修改) -------------
DEFAULT_HOST_PORT="8003"
DEFAULT_HOST_TYPE="1"

# 上报配置 (需配置)
REPORT_ENDPOINT="http://xxx.com/v1/install/report"
REPORT_ACCESS_TOKEN=""
INSTALL_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "RANDOM-$(date +%s)")

# ------------ 全局变量 -----------------------
declare -g SCRIPT_EXIT_STATUS=0
declare -g START_TIME

# =============================================
# 工具函数区
# =============================================

# 显示脚本使用帮助
show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [options] <host_ip> [port] [host_type]

Options:
  -h, --help     显示帮助信息
  -v, --version  显示脚本版本

Arguments:
  host_ip       必填，目标主机IP
  port          可选，默认为 $DEFAULT_HOST_PORT
  host_type     可选，默认为 $DEFAULT_HOST_TYPE

Examples:
  $SCRIPT_NAME 192.168.1.100
  $SCRIPT_NAME 192.168.1.100 8003 2
EOF
}

# 日志记录函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_entry="[$level] $timestamp - $message"
    
    echo "$log_entry" | tee -a "$LOG_FILE" >&2
}

log_info() { log "INFO" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_error() { log "ERROR" "$1"; }

log_success() {
    log_info "$1"
    echo -e "\033[32m✓ $1\033[0m" | tee -a "$LOG_FILE" >&2
}

log_header() {
    echo -e "\n\033[1;36m$1\033[0m" | tee -a "$LOG_FILE" >&2
}

log_section() {
    echo -e "\n\033[1;34m==> $1\033[0m" | tee -a "$LOG_FILE" >&2
}

# 检查并安装必要依赖
ensure_dependencies() {
    local dependencies=("curl" "awk" "sed" "grep")
    local missing=()
    
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少必要依赖: ${missing[*]}"
        return 1
    fi
}

# 检查锁文件防止重复运行
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        log_error "脚本已在运行中 (锁文件存在: $LOCK_FILE)"
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
}

# 清理锁文件
cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# =============================================
# 上报功能
# =============================================

report() {
    # 未配置时直接跳过
    [[ -z "$REPORT_ENDPOINT" || -z "$REPORT_ACCESS_TOKEN" ]] && {
        log_warning "跳过上报: 未配置端点和密钥"
        return 0
    }

    local stage=$1
    local status=$2
    local message=$3
    local timestamp=$(date +%s)
    local http_code
    local response

    log_info "上报阶段状态: stage=$stage, status=$status"

    # 构造JSON数据
    local data=$(jq -n \
        --arg id "$INSTALL_ID" \
        --arg stage "$stage" \
        --arg status "$status" \
        --arg message "$message" \
        --arg version "$SCRIPT_VERSION" \
        --argjson timestamp "$timestamp" \
        '{
            id: $id,
            stage: $stage,
            status: $status,
            message: $message,
            timestamp: $timestamp,
            version: $version
        }')

    # 发送上报请求
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $REPORT_ACCESS_TOKEN" \
        -d "$data" \
        -w "%{http_code}" \
        "$REPORT_ENDPOINT" 2>/dev/null || echo "000")

    http_code=${response: -3}

    if [[ "$http_code" == "200" ]]; then
        log_info "上报成功"
        return 0
    else
        log_warning "上报失败 (HTTP $http_code)"
        return 1
    fi
}

# =============================================
# 函数：Docker 容器部署
# 参数:
#   $1 - 镜像名称 (必填)
#   $2 - 容器名称 (必填)
#   $3 - 端口映射 (可选，格式: "主机端口:容器端口")
#   $4 - 环境变量 (可选，格式: "ENV1=value1 ENV2=value2")
#   $5 - 数据卷映射 (可选，格式: "/host/path:/container/path")
#   $6... - 任意额外的 Docker 参数 (可选)
# =============================================
deploy_docker_container() {
    local image_name=$1
    local container_name=$2
    local port_mapping=${3:-}
    local env_vars=${4:-}
    local volume_mapping=${5:-}
    shift 5  # 移除前5个参数，剩下的都是额外参数
    
    local extra_args=("$@")  # 存储所有额外参数
    local docker_cmd="docker run -d --restart unless-stopped --name $container_name"

    log_section "部署 Docker 容器: $container_name"
    log_info "镜像: $image_name"
    [[ -n "$port_mapping" ]] && log_info "端口映射: $port_mapping"
    [[ -n "$env_vars" ]] && log_info "环境变量: $env_vars"
    [[ -n "$volume_mapping" ]] && log_info "数据卷: $volume_mapping"
    [[ ${#extra_args[@]} -gt 0 ]] && log_info "额外参数: ${extra_args[*]}"

    # 检查Docker是否安装
    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装!"
        report "docker_deployment" "failure" "Docker未安装"
        return 1
    fi

    # 添加端口映射
    [[ -n "$port_mapping" ]] && docker_cmd+=" -p $port_mapping"

    # 添加环境变量
    if [[ -n "$env_vars" ]]; then
        for env in $env_vars; do  # 注意不要加引号，保留分词
            docker_cmd+=" -e $env"
        done
    fi

    # 添加数据卷映射
    [[ -n "$volume_mapping" ]] && docker_cmd+=" -v $volume_mapping"

    # 添加额外参数
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        docker_cmd+=" ${extra_args[*]}"
    fi

    # 添加镜像名称
    docker_cmd+=" $image_name"

    # 检查容器是否已存在
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}\$"; then
        log_info "发现已存在的容器: $container_name"
        
        # 停止并删除现有容器
        log_info "停止并移除现有容器..."
        if ! docker stop "$container_name" >/dev/null || ! docker rm "$container_name" >/dev/null; then
            log_error "无法移除现有容器: $container_name"
            report "docker_deployment" "failure" "无法移除现有容器"
            return 1
        fi
    fi

    # 拉取镜像
    log_info "拉取镜像: $image_name"
    if ! docker pull "$image_name"; then
        log_error "镜像拉取失败: $image_name"
        report "docker_deployment" "failure" "镜像拉取失败"
        return 1
    fi

    # 启动容器
    log_info "启动容器: $container_name"
    log_info "执行命令: $(echo "$docker_cmd" | sed 's/-e [^ ]*/-e ******/g')"  # 隐藏环境变量值
    
    if ! eval "$docker_cmd"; then
        log_error "容器启动失败"
        report "docker_deployment" "failure" "容器启动失败"
        return 1
    fi

    # 检查容器状态
    log_info "检查容器状态..."
    sleep 3  # 给容器一些启动时间
    
    local container_status
    container_status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
    
    if [[ "$container_status" != "running" ]]; then
        log_error "容器未正常运行，当前状态: ${container_status:-unknown}"
        docker logs "$container_name" | tail -n 20 | sed 's/^/  | /' | tee -a "$LOG_FILE"
        report "docker_deployment" "failure" "容器未正常运行"
        return 1
    fi

    log_success "容器部署成功: $container_name (状态: $container_status)"
    report "docker_deployment" "success" "容器部署成功"
    return 0
}

# =============================================
# 函数：部署可执行程序为系统服务
# 参数:
#   $1 - 服务名称 (必填)
#   $2 - 可执行文件路径 (必填)
#   $3 - 运行用户 (可选，默认为root)
#   $4 - 工作目录 (可选，默认为可执行文件目录)
#   $5 - 启动参数 (可选)
# =============================================
deploy_as_service() {
    local service_name=$1
    local exec_path=$2
    local run_user=${3:-root}
    local work_dir=${4:-$(dirname "$exec_path")}
    local exec_args=${5:-}
    local service_file
    local service_type

    log_section "部署服务: $service_name"

    # 检查可执行文件是否存在
    if [[ ! -f "$exec_path" ]]; then
        log_error "可执行文件不存在: $exec_path"
        report "service_deployment" "failure" "可执行文件不存在"
        return 1
    fi

    # 确保可执行文件有执行权限
    if [[ ! -x "$exec_path" ]]; then
        log_info "添加执行权限: $exec_path"
        chmod +x "$exec_path" || {
            log_error "无法添加执行权限"
            report "service_deployment" "failure" "无法添加执行权限"
            return 1
        }
    fi

    # 检测系统使用systemd还是init.d
    if command -v systemctl &>/dev/null; then
        service_type="systemd"
        service_file="/etc/systemd/system/${service_name}.service"
    elif [[ -d "/etc/init.d" ]]; then
        service_type="init.d"
        service_file="/etc/init.d/${service_name}"
    else
        log_error "不支持的初始化系统"
        report "service_deployment" "failure" "不支持的初始化系统"
        return 1
    fi

    # 检查服务是否已存在
    if [[ "$service_type" == "systemd" ]] && systemctl list-unit-files | grep -q "^${service_name}.service"; then
        log_info "停止并禁用现有服务..."
        systemctl stop "$service_name"
        systemctl disable "$service_name"
    elif [[ "$service_type" == "init.d" ]] && [[ -f "$service_file" ]]; then
        log_info "停止现有服务..."
        "$service_file" stop
    fi

    # 创建服务文件
    log_info "创建服务配置文件: $service_file"
    
    if [[ "$service_type" == "systemd" ]]; then
        cat > "$service_file" <<EOF
[Unit]
Description=$service_name Service
After=network.target

[Service]
User=$run_user
WorkingDirectory=$work_dir
ExecStart=$exec_path $exec_args
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=$service_name

[Install]
WantedBy=multi-user.target
EOF
    else # init.d
        cat > "$service_file" <<EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          $service_name
# Required-Start:    \$local_fs \$network
# Required-Stop:     \$local_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: $service_name Service
# Description:       Service for $service_name
### END INIT INFO

case "\$1" in
    start)
        echo "Starting $service_name"
        su - $run_user -c "cd $work_dir && $exec_path $exec_args &"
        ;;
    stop)
        echo "Stopping $service_name"
        pkill -f "$exec_path"
        ;;
    restart)
        \$0 stop
        \$0 start
        ;;
    status)
        if pgrep -f "$exec_path" >/dev/null; then
            echo "$service_name is running"
        else
            echo "$service_name is not running"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF
        chmod +x "$service_file"
    fi

    # 启用并启动服务
    if [[ "$service_type" == "systemd" ]]; then
        log_info "重新加载systemd配置..."
        systemctl daemon-reload || {
            log_error "systemd配置重载失败"
            report "service_deployment" "failure" "systemd配置重载失败"
            return 1
        }
        
        log_info "启用并启动服务..."
        systemctl enable "$service_name" && systemctl start "$service_name" || {
            log_error "服务启动失败"
            systemctl status "$service_name" | tee -a "$LOG_FILE"
            report "service_deployment" "failure" "服务启动失败"
            return 1
        }
    else
        log_info "注册并启动服务..."
        update-rc.d "$service_name" defaults && service "$service_name" start || {
            log_error "服务启动失败"
            report "service_deployment" "failure" "服务启动失败"
            return 1
        }
    fi

    # 验证服务状态
    log_info "检查服务状态..."
    sleep 2
    
    if [[ "$service_type" == "systemd" ]]; then
        if ! systemctl is-active --quiet "$service_name"; then
            log_error "服务未正常运行"
            systemctl status "$service_name" | tee -a "$LOG_FILE"
            report "service_deployment" "failure" "服务未正常运行"
            return 1
        fi
    else
        if ! pgrep -f "$exec_path" >/dev/null; then
            log_error "服务未正常运行"
            report "service_deployment" "failure" "服务未正常运行"
            return 1
        fi
    fi

    log_success "服务部署成功: $service_name"
    report "service_deployment" "success" "服务部署成功"
    return 0
}

# =============================================
# 函数：使用 Helm 部署应用
# 参数:
#   $1 - 发布名称 (必填)
#   $2 - Chart 位置 (必填，可以是repo/chart或本地路径)
#   $3 - 命名空间 (可选，默认为default)
#   $4 - values.yaml 文件路径 (可选)
#   $5... - 额外 Helm 参数 (可选)
# =============================================
deploy_with_helm() {
    local release_name=$1
    local chart_location=$2
    local namespace=${3:-default}
    local values_file=${4:-}
    shift 4  # 移除前4个参数，剩下的都是额外参数
    
    local extra_args=("$@")
    local helm_cmd="helm upgrade --install $release_name $chart_location --namespace $namespace"

    log_section "Helm 部署: $release_name ($chart_location)"

    # 检查 Helm 是否安装
    if ! command -v helm &>/dev/null; then
        log_error "Helm 未安装!"
        report "helm_deployment" "failure" "Helm未安装"
        return 1
    fi

    # 添加 values 文件
    [[ -n "$values_file" ]] && {
        [[ ! -f "$values_file" ]] && {
            log_error "Values 文件不存在: $values_file"
            report "helm_deployment" "failure" "Values文件不存在"
            return 1
        }
        helm_cmd+=" -f $values_file"
    }

    # 添加额外参数
    [[ ${#extra_args[@]} -gt 0 ]] && helm_cmd+=" ${extra_args[*]}"

    # 检查并创建命名空间（如果不存在）
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        log_info "创建命名空间: $namespace"
        kubectl create namespace "$namespace" || {
            log_error "无法创建命名空间: $namespace"
            report "helm_deployment" "failure" "命名空间创建失败"
            return 1
        }
    fi

    # 检查是否来自仓库（repo/chart格式）
    if [[ "$chart_location" == *"/"* && ! -d "$chart_location" ]]; then
        local repo_name chart_name
        repo_name=$(echo "$chart_location" | cut -d/ -f1)
        chart_name=$(echo "$chart_location" | cut -d/ -f2)
        
        # 检查仓库是否已添加
        if ! helm repo list | grep -q "^$repo_name"; then
            log_error "Helm 仓库未添加: $repo_name"
            report "helm_deployment" "failure" "Helm仓库未添加"
            return 1
        fi
        
        # 更新仓库
        log_info "更新 Helm 仓库..."
        helm repo update || {
            log_error "Helm 仓库更新失败"
            report "helm_deployment" "failure" "仓库更新失败"
            return 1
        }
    fi

    # 执行 Helm 部署
    log_info "执行 Helm 部署..."
    log_info "命令: $helm_cmd"
    
    if ! eval "$helm_cmd"; then
        log_error "Helm 部署失败"
        report "helm_deployment" "failure" "Helm部署失败"
        return 1
    fi

    # 验证部署状态
    log_info "验证部署状态..."
    sleep 5  # 给部署一些时间
    
    if ! helm status "$release_name" --namespace "$namespace"; then
        log_error "Helm 发布验证失败"
        report "helm_deployment" "failure" "发布验证失败"
        return 1
    fi

    # 检查资源是否就绪
    log_info "检查资源就绪状态..."
    local deployments
    deployments=$(kubectl get deployments -n "$namespace" -l "app.kubernetes.io/instance=$release_name" -o name 2>/dev/null)
    
    if [[ -n "$deployments" ]]; then
        for deploy in $deployments; do
            kubectl rollout status "$deploy" -n "$namespace" --timeout=120s || {
                log_error "部署未就绪: $deploy"
                kubectl describe "$deploy" -n "$namespace" | tee -a "$LOG_FILE"
                kubectl logs "$deploy" -n "$namespace" --all-containers | tail -n 20 | tee -a "$LOG_FILE"
                report "helm_deployment" "failure" "资源未就绪"
                return 1
            }
        done
    fi

    log_success "Helm 部署成功: $release_name"
    report "helm_deployment" "success" "Helm部署成功"
    return 0
}

# =============================================
# 函数：添加 Helm 仓库
# 参数:
#   $1 - 仓库名称 (必填)
#   $2 - 仓库URL (必填)
#   $3 - 用户名 (可选)
#   $4 - 密码 (可选)
# =============================================
add_helm_repo() {
    local repo_name=$1
    local repo_url=$2
    local username=${3:-}
    local password=${4:-}
    local repo_cmd="helm repo add $repo_name $repo_url"

    log_section "添加 Helm 仓库: $repo_name"

    # 检查 Helm 是否安装
    if ! command -v helm &>/dev/null; then
        log_error "Helm 未安装!"
        report "helm_repo" "failure" "Helm未安装"
        return 1
    fi

    # 添加认证信息（如果提供）
    [[ -n "$username" && -n "$password" ]] && repo_cmd+=" --username $username --password $password"

    # 检查仓库是否已存在
    if helm repo list | grep -q "^$repo_name"; then
        log_info "仓库已存在，更新中..."
        repo_cmd="helm repo update"
    fi

    # 执行仓库添加/更新
    log_info "执行命令: $repo_cmd"
    if ! eval "$repo_cmd"; then
        log_error "Helm 仓库操作失败"
        report "helm_repo" "failure" "仓库操作失败"
        return 1
    fi

    log_success "Helm 仓库配置成功: $repo_name"
    report "helm_repo" "success" "仓库配置成功"
    return 0
}

# =============================================
# 各阶段功能
# =============================================

# 初始化阶段
init() {
    START_TIME=$(date +%s)
    log_header "开始执行安装脚本 (版本 $SCRIPT_VERSION)"
    report "initialization" "started" "安装流程启动"

    # 检查root权限
    [[ $EUID -ne 0 ]] && log_warning "建议使用root用户执行此脚本"

    # 显示基础信息
    log_info "执行批次: $INSTALL_ID"
    log_info "脚本名称: $SCRIPT_NAME"
    log_info "日志文件: $LOG_FILE"
}

# 收集系统信息
collect_system_info() {
    log_section "收集系统信息"
    local os_info os_version kernel_version cpu_cores cpu_model memory_gb memory_free_gb
    local disk_gb disk_free_gb disk_used_percent cgroup_version

    # 操作系统信息
    if [[ -f /etc/os-release ]]; then
        os_info=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        os_version=$(awk -F= '/^VERSION_ID/{print $2}' /etc/os-release | tr -d '"')
    elif [[ -f /etc/redhat-release ]]; then
        os_info=$(cat /etc/redhat-release)
    else
        os_info="Unknown"
    fi
    
    # 内核和CPU信息
    kernel_version=$(uname -r)
    cpu_cores=$(nproc)
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    
    # 内存信息
    memory_gb=$(free -g | awk '/Mem:/{print $2}')
    memory_free_gb=$(free -g | awk '/Mem:/{print $4}')
    
    # 磁盘信息
    disk_gb=$(df -BG --total | awk '/total/{print $2}' | tr -d 'G')
    disk_free_gb=$(df -BG --total | awk '/total/{print $4}' | tr -d 'G')
    disk_used_percent=$(df -h --total | awk '/total/{print $5}')
    
    # cgroup版本
    cgroup_version=$(stat -fc %T /sys/fs/cgroup/)
    [[ "$cgroup_version" == "cgroup2fs" ]] && cgroup_version="v2" || cgroup_version="v1"

    # 导出环境变量
    export OS_INFO="$os_info"
    export OS_VERSION="${os_version:-unknown}"
    export KERNEL_VERSION="$kernel_version"
    export CPU_CORES="$cpu_cores"
    export CPU_MODEL="$cpu_model"
    export MEMORY_GB="$memory_gb"
    export MEMORY_FREE_GB="$memory_free_gb"
    export DISK_GB="$disk_gb"
    export DISK_FREE_GB="$disk_free_gb"
    export DISK_USED_PERCENT="$disk_used_percent"
    export CGROUP_VERSION="$cgroup_version"

    # 显示信息
    log_info "操作系统: $OS_INFO $OS_VERSION"
    log_info "内核版本: $KERNEL_VERSION"
    log_info "CPU: $CPU_CORES核 $CPU_MODEL"
    log_info "MEM: 总计${MEMORY_GB}GB 可用${MEMORY_FREE_GB}GB"
    log_info "DISK: 总计${DISK_GB}GB 可用${DISK_FREE_GB}GB (使用率$DISK_USED_PERCENT)"
    log_info "Cgroups版本: $CGROUP_VERSION"
}

# 收集主机信息
collect_host_info() {
    log_section "收集主机信息"
    local hostname host_ip host_type network_interfaces

    hostname=$(hostname)
    host_ip=${HOST_IP:-$(hostname -I | awk '{print $1}')}
    
    # 检测主机类型
    if [[ -f /sys/hypervisor/uuid ]] || [[ -f /sys/devices/virtual/dmi/id/product_uuid ]]; then
        host_type="vm"
    elif grep -q "container" /proc/1/environ 2>/dev/null || grep -q "container" /proc/self/cgroup; then
        host_type="container"
    else
        host_type="physical"
    fi
    
    # 网络信息
    network_interfaces=$(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ',')

    # 导出环境变量
    export HOSTNAME="$hostname"
    export HOST_IP="$host_ip"
    export HOST_TYPE="$host_type"
    export NETWORK_INTERFACES="${network_interfaces%,}"

    log_info "主机名: $HOSTNAME"
    log_info "IP地址: $HOST_IP"
    log_info "主机类型: $HOST_TYPE"
    log_info "网络接口: $NETWORK_INTERFACES"
}

# 收集Docker信息
collect_docker_info() {
    log_section "收集Docker信息"
    local docker_version docker_images docker_containers docker_storage_driver
    local docker_cgroup_driver docker_compose_version compose_output

    if ! command -v docker &>/dev/null; then
        log_warning "Docker未安装!"
        export DOCKER_VERSION="未安装"
        export DOCKER_IMAGES=0
        export DOCKER_CONTAINERS=0
        export DOCKER_COMPOSE_VERSION="未安装"
        return
    fi

    docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
    docker_images=$(docker images -q | wc -l)
    docker_containers=$(docker ps -a -q | wc -l)
    docker_storage_driver=$(docker info 2>/dev/null | awk '/Storage Driver:/{print $3}')
    docker_cgroup_driver=$(docker info 2>/dev/null | awk '/Cgroup Driver:/{print $3}')

    # Docker Compose版本检测
    if command -v docker-compose &>/dev/null; then
        compose_output=$(docker-compose --version)
        case "$compose_output" in
            *"version v"*) docker_compose_version=$(echo "$compose_output" | awk '{print $4}' | tr -d 'v') ;;
            *"version "*) docker_compose_version=$(echo "$compose_output" | awk '{print $3}' | tr -d ',') ;;
            *) docker_compose_version="未知格式" ;;
        esac
    else
        docker_compose_version="未安装"
    fi

    # 导出环境变量
    export DOCKER_VERSION="$docker_version"
    export DOCKER_IMAGES="$docker_images"
    export DOCKER_CONTAINERS="$docker_containers"
    export DOCKER_STORAGE_DRIVER="$docker_storage_driver"
    export DOCKER_CGROUP_DRIVER="$docker_cgroup_driver"
    export DOCKER_COMPOSE_VERSION="$docker_compose_version"

    log_info "Docker版本: $DOCKER_VERSION"
    log_info "Docker镜像数量: $DOCKER_IMAGES"
    log_info "Docker容器数量: $DOCKER_CONTAINERS (运行中: $(docker ps -q | wc -l))"
    log_info "存储驱动: $DOCKER_STORAGE_DRIVER"
    log_info "Cgroups驱动: $DOCKER_CGROUP_DRIVER"
    log_info "Docker Compose版本: $DOCKER_COMPOSE_VERSION"
}

# 部署阶段
deploy() {
    log_section "开始部署"
    report "deployment" "started" "部署流程启动"
    
    # 这里添加实际的部署逻辑
    log_info "执行部署操作..."
    
    log_success "部署完成"
}

# 验证阶段
validate() {
    log_section "验证部署"
    
    # 这里添加验证逻辑
    log_info "执行验证检查..."
    
    log_success "验证通过"
}

# 清理阶段
cleanup() {
    log_section "清理临时文件"
    report "cleanup" "started" "清理临时文件"
    
    # 这里添加清理逻辑
    log_info "清理临时文件和资源..."
    
    log_success "清理完成"
}

# 总结阶段
summary() {
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    log_header "安装脚本执行完成"
    log_info "总耗时: $duration 秒"
    report "installation" "completed" "安装流程完成"
    
    if [[ $SCRIPT_EXIT_STATUS -eq 0 ]]; then
        log_success "所有步骤成功完成"
    else
        log_error "某些步骤失败，请检查日志"
    fi

    log_info "日志文件: $LOG_FILE"
}

# =============================================
# 主函数
# =============================================

main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $SCRIPT_VERSION"
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    # 参数校验
    [[ $# -lt 1 ]] && {
        log_error "缺少必要参数: host_ip"
        show_help
        exit 1
    }

    # 设置环境变量
    export HOST_IP="$1"
    export HOST_PORT="${2:-$DEFAULT_HOST_PORT}"
    export HOST_TYPE="${3:-$DEFAULT_HOST_TYPE}"

    # 初始化环境
    check_lock
    trap cleanup_lock EXIT
    ensure_dependencies
    init

    # 执行各阶段
    collect_system_info || SCRIPT_EXIT_STATUS=1
    collect_host_info || SCRIPT_EXIT_STATUS=1
    collect_docker_info || SCRIPT_EXIT_STATUS=1
    
    [[ $SCRIPT_EXIT_STATUS -eq 0 ]] && deploy || SCRIPT_EXIT_STATUS=1
    [[ $SCRIPT_EXIT_STATUS -eq 0 ]] && validate || SCRIPT_EXIT_STATUS=1
    [[ $SCRIPT_EXIT_STATUS -eq 0 ]] && cleanup || SCRIPT_EXIT_STATUS=1

    # 总结
    summary
    exit $SCRIPT_EXIT_STATUS
}

# 执行主函数
main "$@"
