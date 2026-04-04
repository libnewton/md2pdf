# md2pdf

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`md2pdf` is a static, browser-first Markdown to PDF tool. It converts Markdown locally with Pandoc and SwiftLaTeX, shows a live PDF preview, and keeps image handling inside the browser.

- **Site**: [https://markdown2pdf.github.io/](https://markdown2pdf.github.io/)

## Features

- **Client-Side Processing:** Converts Markdown to PDF entirely within your browser—no backend server required.
- **Live Preview:** See your PDF output update in real-time as you type.
- **Local Image Handling:** Insert and process images directly in the browser.
- **Privacy First:** Your data never leaves your device.

## Tech stack

- Vanilla HTML, CSS, and JavaScript.
- [Pandoc](https://pandoc.org/) compiled to WebAssembly for Markdown -> LaTeX
- [SwiftLaTeX](https://github.com/SwiftLaTeX/SwiftLaTeX) / PdfTeX in the browser for PDF generation
- [EasyMDE](https://easymde.ibrahimcesar.cloud/) and [CodeMirror](https://codemirror.net/) for the editor experience
- [Eisvogel](https://github.com/Wandmalfarben/pandoc-latex-template) (by Wandmalfarben) for the beautiful Pandoc LaTeX template

> **Tip:** Works excellent with the [Outline](https://getoutline.com/) "Copy Markdown" feature for beautifully formatted PDF creation.
 
## Getting Started

### Local use

Serve the repository with any small static HTTP server, then open the app in a browser.

1. Clone the repository:
   ```bash
   git clone https://github.com/libnewton/md2pdf.git
   cd md2pdf
   ```

2. Start a local server:
   ```bash
   python -m http.server 8000
   ```

3. Open `http://localhost:8000` in your browser.

## Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page.

## License

This project is [MIT](LICENSE.md) licensed.