#!/bin/sh
# HwScope CRLF Fix — run this first if copied from Windows
sed -i 's/\r$//' hwscope.sh lib/*.sh modules/*.sh conf/*
echo "Done. Run: sudo bash hwscope.sh"
