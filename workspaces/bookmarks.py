#!/usr/bin/python
# -*- coding: UTF-8 -*-
"""
Chrome书签转换工具

功能: 将Chrome浏览器导出的HTML格式书签转换为多种格式(Excel/CSV/JSON)
作者: Liu Kun
日期: 2025.09.01
版本: 2.0
"""

import pandas as pd
from bs4 import BeautifulSoup
import argparse
import os
import sys
from datetime import datetime
from typing import List, Dict, Optional, Any, Callable
import logging
import json
import csv

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('bookmarks.log', encoding='utf-8')
    ]
)
logger = logging.getLogger(__name__)


class BookmarkDecoder:
    """ 书签解码器 - 负责解析 HTML 格式的书签文件 """

    def __init__(self):
        self.total_bookmarks = 0
        self.total_folders = 0
        self.processed_files = 0

    def decode(self, html_content: str) -> List[Dict[str, Any]]:
        """
        解析 HTML 内容为书签数据

        Args:
            html_content: HTML 文件内容

        Returns:
            List[Dict]: 书签数据
        """
        try:
            soup = BeautifulSoup(html_content, 'html.parser')
            root = soup.find('dl')

            if not root:
                logger.warning("未找到有效的根标签")
                return []

            return self._parse_folder(root)

        except Exception as e:
            logger.error(f"解码 HTML 内容时出错: {e}")
            raise

    def decode_file(self, file_path: str) -> List[Dict[str, Any]]:
        """
        从 HTML 文件中解码书签数据

        Args:
            file_path: HTML 文件路径

        Returns:
            List[Dict]: 书签数据
        """
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"文件 {file_path} 不存在")

        try:
            encodings = ['utf-8', 'gbk', 'latin-1', 'iso-8859-1']
            html_content = None

            for encoding in encodings:
                try:
                    with open(file_path, 'r', encoding=encoding) as file:
                        html_content = file.read()
                    logger.info(f"使用编码: {encoding}")
                    break
                except UnicodeDecodeError:
                    continue

            if html_content is None:
                raise UnicodeDecodeError("无法使用任何编码读取文件")

            self.processed_files += 1
            return self.decode(html_content)

        except Exception as e:
            logger.error(f"读取文件时出错: {e}")
            raise

    def _parse_folder(self, element: BeautifulSoup) -> List[Dict]:
        """
        解析文件夹结构

        Args:
            element: 当前元素对象

        Returns:
            List[Dict]: 书签数据
        """
        bookmarks = []

        # 查找所有的 <a> 标签(书签链接)
        for link in element.find_all('a'):

            # 查找父文件夹
            folder_path = []
            parent = link.find_parent('dl')
            while parent:
                folder_tag = parent.find_previous_sibling('h3')
                if folder_tag and folder_tag.string:
                    folder_path.insert(0, folder_tag.string)
                parent = parent.find_parent('dl')
            # 组装文件夹路径
            folder = ' > '.join(folder_path) if folder_path else '书签栏'

            # 处理书签链接
            bookmark = self._parse_bookmark(link, folder)
            if bookmark:
                bookmarks.append(bookmark)
                self.total_bookmarks += 1

        return bookmarks

    def _parse_bookmark(self, a_element: BeautifulSoup, folder: str) -> Optional[Dict]:
        """
        解析单个书签元素

        Args:
            a_element: A标签元素
            folder: 文件夹路径

        Returns:
            Optional[Dict]: 书签数据字典或None
        """
        try:
            title = a_element.get_text(strip=True) or "无标题"
            url = a_element.get('href', '').strip()

            return {
                'title': title,
                'url': url,
                'domain': self._extract_domain(url),
                'folder_path': self._clean_folder_path(folder),
                'add_date': self._convert_timestamp(a_element.get('add_date', '')),
                'last_modified': self._convert_timestamp(a_element.get('last_modified', '')),
                'has_icon': bool(a_element.get('icon')),
                'bookmark_type': self._get_bookmark_type(url),
                'icon_data': a_element.get('icon', '')
            }

        except Exception as e:
            logger.warning(f"解析书签时出错: {e}")
            return None

    @staticmethod
    def _clean_folder_path(path: str) -> str:
        """清理文件夹路径"""
        if not path:
            return "书签栏"
        return path.strip().lstrip('>').strip()
    
    @staticmethod
    def _convert_timestamp(timestamp: str) -> str:
        """转换Unix时间戳为可读格式"""
        if timestamp and timestamp.isdigit():
            try:
                return datetime.fromtimestamp(int(timestamp)).strftime("%Y-%m-%d %H:%M:%S")
            except (ValueError, OSError):
                pass
        return "未知日期"
    
    @staticmethod
    def _extract_domain(url: str) -> str:
        """从URL提取域名"""
        if not url or '://' not in url:
            return ""
        
        try:
            domain = url.split('://')[1].split('/')[0]
            return domain.replace('www.', '')
        except:
            return ""
    
    @staticmethod
    def _get_bookmark_type(url: str) -> str:
        """根据URL判断书签类型"""
        if not url:
            return "unknown"
        
        url_lower = url.lower()
        if url_lower.startswith(('http://', 'https://')):
            return "webpage"
        elif url_lower.startswith('file://'):
            return "local_file"
        elif url_lower.startswith('javascript:'):
            return "javascript"
        elif url_lower.startswith('mailto:'):
            return "email"
        else:
            return "other"


class BookmarkEncoder:
    """书签编码器 - 负责将书签数据编码为不同格式"""
    
    # 输出格式注册表
    _formats = {}
    
    @classmethod
    def register_format(cls, format_name: str, encoder_func: Callable):
        """注册新的输出格式"""
        cls._formats[format_name] = encoder_func
    
    @classmethod
    def get_available_formats(cls) -> List[str]:
        """获取所有可用的输出格式"""
        return list(cls._formats.keys())
    
    @classmethod
    def encode(cls, bookmarks: List[Dict], output_format: str, 
              output_file: Optional[str] = None, **kwargs) -> Any:
        """
        将书签数据编码为指定格式
        
        Args:
            bookmarks: 书签数据列表
            output_format: 输出格式名称
            output_file: 输出文件路径(可选)
            **kwargs: 编码器特定参数
            
        Returns:
            Any: 编码后的数据
            
        Raises:
            ValueError: 不支持的格式
        """
        if output_format not in cls._formats:
            raise ValueError(f"不支持的输出格式: {output_format}")
        
        encoder = cls._formats[output_format]
        return encoder(bookmarks, output_file, **kwargs)


# 注册内置编码器
def _encode_excel(bookmarks: List[Dict], output_file: str, **kwargs) -> str:
    """Excel编码器"""
    if not output_file:
        output_file = f"bookmarks_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
    elif not output_file.endswith('.xlsx'):
        output_file += '.xlsx'
    
    df = pd.DataFrame(bookmarks)
    
    # 重命名列名为中文
    column_mapping = {
        'title': '标题',
        'url': '网址',
        'domain': '域名',
        'folder_path': '文件夹路径',
        'add_date': '添加日期',
        'last_modified': '最后修改',
        'has_icon': '是否有图标',
        'bookmark_type': '书签类型',
        'icon_data': '图标数据'
    }
    df.rename(columns=column_mapping, inplace=True)
    
    with pd.ExcelWriter(output_file, engine='openpyxl') as writer:
        df.to_excel(writer, sheet_name='书签列表', index=False)
        
        # 添加统计信息
        stats = {
            '统计项': ['总书签数', '网页书签', '本地文件', '其他类型'],
            '数量': [
                len(bookmarks),
                len([b for b in bookmarks if b['bookmark_type'] == 'webpage']),
                len([b for b in bookmarks if b['bookmark_type'] == 'local_file']),
                len([b for b in bookmarks if b['bookmark_type'] in ['other', 'unknown']])
            ]
        }
        pd.DataFrame(stats).to_excel(writer, sheet_name='统计信息', index=False)
    
    return output_file

def _encode_csv(bookmarks: List[Dict], output_file: str, **kwargs) -> str:
    """CSV编码器"""
    if not output_file:
        output_file = f"bookmarks_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    elif not output_file.endswith('.csv'):
        output_file += '.csv'
    
    with open(output_file, 'w', newline='', encoding='utf-8-sig') as f:
        if bookmarks:
            writer = csv.DictWriter(f, fieldnames=bookmarks[0].keys())
            writer.writeheader()
            writer.writerows(bookmarks)
    
    return output_file

def _encode_json(bookmarks: List[Dict], output_file: str, **kwargs) -> str:
    """JSON编码器"""
    if not output_file:
        output_file = f"bookmarks_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    elif not output_file.endswith('.json'):
        output_file += '.json'
    
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(bookmarks, f, ensure_ascii=False, indent=2)
    
    return output_file

def _encode_stdout(bookmarks: List[Dict], output_file: str, **kwargs) -> None:
    """标准输出编码器"""
    for i, bookmark in enumerate(bookmarks, 1):
        print(f"{i:3d}. {bookmark['title']}")
        print(f"    网址: {bookmark['url']}")
        print(f"    路径: {bookmark['folder_path']}")
        print(f"    类型: {bookmark['bookmark_type']}")
        print("-" * 60)
    
    print(f"\n总计: {len(bookmarks)} 个书签")

# 注册内置格式
BookmarkEncoder.register_format('excel', _encode_excel)
BookmarkEncoder.register_format('csv', _encode_csv)
BookmarkEncoder.register_format('json', _encode_json)
BookmarkEncoder.register_format('stdout', _encode_stdout)


class ChromeBookmarkConverter:
    """Chrome书签转换器 - 协调解码和编码过程"""
    
    def __init__(self):
        self.decoder = BookmarkDecoder()
        self.encoder = BookmarkEncoder()
    
    def convert(self, input_file: str, output_format: str = 'excel',
               output_file: Optional[str] = None, **kwargs) -> Any:
        """
        转换书签文件
        
        Args:
            input_file: 输入HTML文件路径
            output_format: 输出格式
            output_file: 输出文件路径
            **kwargs: 编码器参数
            
        Returns:
            Any: 转换结果
        """
        logger.info(f"开始转换: {input_file} -> {output_format}")
        
        # 解码阶段
        bookmarks = self.decoder.decode_file(input_file)
        
        if not bookmarks:
            logger.warning("未找到书签数据")
            return None
        
        logger.info(f"解码完成: 找到 {len(bookmarks)} 个书签")
        
        # 编码阶段
        try:
            result = self.encoder.encode(bookmarks, output_format, output_file, **kwargs)
            logger.info(f"转换完成: {output_format.upper()} 格式")
            return result
            
        except Exception as e:
            logger.error(f"编码过程中出错: {e}")
            raise


def setup_argument_parser() -> argparse.ArgumentParser:
    """设置命令行参数解析器"""
    parser = argparse.ArgumentParser(
        description='Chrome书签转换工具 - 将HTML书签转换为多种格式',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 转换为Excel格式(默认)
  python bookmarks.py bookmarks.html
  
  # 指定输出格式和文件
  python bookmarks.py bookmarks.html -f csv -o output.csv
  
  # 转换为JSON并显示详细信息
  python bookmarks.py bookmarks.html -f json -v
  
  # 批量转换多个文件
  python bookmarks.py *.html -f excel
  
  # 仅显示统计信息
  python bookmarks.py bookmarks.html -f stdout --stats-only
        """
    )

    parser.add_argument(
        'input_files', 
        nargs='+',
        help='输入的HTML书签文件路径(支持通配符)'
    )

    parser.add_argument(
        '-f', '--format',
        choices=BookmarkEncoder.get_available_formats(),
        default='excel',
        help='输出格式 (默认: excel)'
    )

    parser.add_argument(
        '-o', '--output',
        help='输出文件路径(对于多文件处理，此参数作为前缀使用)'
    )

    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='显示详细日志信息'
    )

    parser.add_argument(
        '--stats-only',
        action='store_true',
        help='仅显示统计信息，不生成输出文件'
    )

    parser.add_argument(
        '--no-backup',
        action='store_true',
        help='不创建备份文件'
    )

    parser.add_argument(
        '--encoding',
        default='utf-8',
        help='输入文件编码 (默认: utf-8)'
    )

    return parser


def main():
    """主函数"""
    parser = setup_argument_parser()
    args = parser.parse_args()
    
    # 设置日志级别
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    converter = ChromeBookmarkConverter()
    results = []
    
    try:
        for input_file in args.input_files:
            if not os.path.exists(input_file):
                logger.warning(f"文件不存在: {input_file}")
                continue
            
            # 确定输出文件名
            output_file = args.output
            if output_file and len(args.input_files) > 1:
                base_name = os.path.splitext(os.path.basename(input_file))[0]
                output_file = f"{args.output}_{base_name}"

            # 执行转换
            if args.stats_only:
                bookmarks = converter.decoder.decode_file(input_file)
                print(f"\n文件: {input_file}")
                print(f"书签数: {len(bookmarks)}")
                print(f"文件夹数: {converter.decoder.total_folders}")
            else:
                result = converter.convert(
                    input_file, 
                    args.format, 
                    output_file,
                    encoding=args.encoding
                )
                results.append(result)
        
        # 显示总结信息
        if results and not args.stats_only:
            print(f"\n✅ 转换完成!")
            print(f"📊 处理文件: {len(results)} 个")
            print(f"📚 总书签数: {converter.decoder.total_bookmarks}")
            print(f"📁 总文件夹数: {converter.decoder.total_folders}")
            
            for result in results:
                if result and isinstance(result, str):
                    print(f"💾 输出文件: {result}")
        
        return 0
        
    except Exception as e:
        logger.error(f"程序执行出错: {e}")
        return 1


if __name__ == "__main__":
    # 示例用法
    # converter = ChromeBookmarkConverter()
    # converter.convert("bookmarks.html", "excel", "output.xlsx")

    sys.exit(main())