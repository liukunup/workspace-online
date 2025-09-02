# 工作日志

#### 2025/09/01 Chrome 书签转换工具

✈ 导航到 [Code](bookmark/run.py)

- 支持将 Chrome 导出的 HTML 书签数据进行解析，并转换成各种不同的格式

- 支持 [Flare](https://github.com/soulteary/docker-flare) 格式

```plaintext
# 转换为Excel格式(默认)
python run.py bookmarks.html

# 指定输出格式和文件
python run.py bookmarks.html -f csv -o output.csv

# 转换为JSON并显示详细信息
python run.py bookmarks.html -f json -v

# 批量转换多个文件
python run.py *.html -f excel

# 仅显示统计信息
python bookmarks.py bookmarks.html -f stdout --stats-only
```
