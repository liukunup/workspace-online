#!/usr/bin/python
# -*- coding: UTF-8 -*-
# brief : 将Chrome HTML书签转换为Excel格式
# author: Liu Kun
# date  : 2025.09.01

import pandas as pd
from bs4 import BeautifulSoup
import argparse
import os
from datetime import datetime

def html_to_excel(html_file, excel_file=None):
    """
    将Chrome HTML书签文件转换为Excel格式
    
    参数:
    html_file: 输入的HTML书签文件路径
    excel_file: 输出的Excel文件路径(可选)
    """

    # 如果没有指定输出文件，使用输入文件名+时间戳
    if excel_file is None:
        base_name = os.path.splitext(html_file)[0]
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        excel_file = f"{base_name}_{timestamp}.xlsx"

    try:
        # 读取HTML文件
        with open(html_file, 'r', encoding='utf-8') as file:
            html_content = file.read()
        
        # 使用BeautifulSoup解析HTML
        soup = BeautifulSoup(html_content, 'html.parser')
        
        # 提取书签数据
        bookmarks = []
        
        # 查找所有的<a>标签(书签链接)
        for link in soup.find_all('a'):
            title = link.string if link.string else "无标题"
            url = link.get('href', '')
            add_date = link.get('add_date', '')
            icon = link.get('icon', '')
            
            # 查找父文件夹
            folder_path = []
            parent = link.find_parent('dl')
            while parent:
                folder_tag = parent.find_previous_sibling('h3')
                if folder_tag and folder_tag.string:
                    folder_path.insert(0, folder_tag.string)
                parent = parent.find_parent('dl')
            
            folder = ' > '.join(folder_path) if folder_path else '书签栏'
            
            # 转换时间戳
            if add_date:
                try:
                    add_date = datetime.fromtimestamp(int(add_date))
                    add_date = add_date.strftime("%Y-%m-%d %H:%M:%S")
                except (ValueError, OSError):
                    pass
            
            bookmarks.append({
                '标题': title,
                '网址': url,
                '文件夹': folder,
                '添加日期': add_date,
                '图标': icon
            })
        
        # 创建DataFrame
        df = pd.DataFrame(bookmarks)
        
        # 保存到Excel
        df.to_excel(excel_file, index=False, engine='openpyxl')
        
        print(f"成功转换 {len(bookmarks)} 个书签")
        print(f"输出文件: {excel_file}")

        return True
        
    except Exception as e:
        print(f"转换过程中出现错误: {str(e)}")
        return False

def main():
    parser = argparse.ArgumentParser(description='将Chrome HTML书签转换为Excel格式')
    parser.add_argument('input', help='输入的HTML书签文件路径')
    parser.add_argument('-o', '--output', help='输出的Excel文件路径(可选)')
    
    args = parser.parse_args()
    
    # 检查输入文件是否存在
    if not os.path.exists(args.input):
        print(f"错误: 文件 '{args.input}' 不存在")
        return
    
    html_to_excel(args.input, args.output)

if __name__ == "__main__":
    # 如果直接运行，使用示例
    # 也可以使用命令行参数: python script.py bookmarks.html -o output.xlsx
    main()