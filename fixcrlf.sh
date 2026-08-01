#!/bin/sh
# HwScope CRLF Fix — run this first if copied from Windows
sed -i 's/\r$//' hwscope.sh lib/*.sh modules/*.sh tools/*.sh test/*.sh conf/*
echo "Done. Run: sudo bash hwscope.sh"
