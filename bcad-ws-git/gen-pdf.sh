#! /bin/bash

repomix --style markdown
pandoc repomix-output.md -o output.pdf --pdf-engine=weasyprint
rm repomix-output.md

