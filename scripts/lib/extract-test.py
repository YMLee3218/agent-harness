#!/usr/bin/env python3
"""Extract imports + fixtures + one test function from a Python test file."""
import ast, sys

path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
lines = src.splitlines()
tree = ast.parse(src)
keep = set()
for node in tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        keep.update(range(node.lineno - 1, node.end_lineno))
    elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        if not node.name.startswith("test_"):
            keep.update(range(node.lineno - 1, node.end_lineno))
        elif node.name == name:
            start = node.decorator_list[0].lineno if node.decorator_list else node.lineno
            keep.update(range(start - 1, node.end_lineno))
for i, line in enumerate(lines):
    if i in keep:
        print(line)
