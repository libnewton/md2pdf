const TEXLIVE_ENDPOINT = "/texlive-assets/";
// const TEXLIVE_ENDPOINT = "https://texlive.texlyre.org/";
const SUPPORT_FILES = [
  "eisvogel.latex",
  "header.tex",
  "pdf-fixes-emoji-map.lua",
  "pdf-fixes.lua",
  "pdf-fixes-unicode-map.lua",
  "vscode-light.theme"
];

export function createPdfBuilder() {
  let preparePromise = null;
  let supportFilesPromise = null;
  let pandocModule = null;
  let texEngine = null;

  async function prepare() {
    if (!preparePromise) {
      preparePromise = boot().catch((error) => {
        preparePromise = null;
        throw error;
      });
    }

    return preparePromise;
  }

  async function build({ markdown, hidePageNumbers, mediaFiles, onStage = () => {} }) {
    await prepare();

    onStage("Converting markdown...");
    const supportFiles = await loadSupportFiles();
    const result = await pandocModule.convert(createPandocOptions(hidePageNumbers), markdown, {
      ...supportFiles,
      ...mediaFiles
    });

    const latexSource = result.stdout || "";
    if (!latexSource.trim()) {
      throw new Error(formatLog(result.stderr, result.warnings));
    }

    onStage("Compiling LaTeX...");
    texEngine.flushCache();
    texEngine.setEngineMainFile("document.tex");
    texEngine.writeMemFSFile("/work/document.tex", latexSource);

    const mediaEntries = Object.entries(mediaFiles);
    if (mediaEntries.length) {
      texEngine.makeMemFSFolder("media");
    }

    for (const [name, blob] of mediaEntries) {
      texEngine.writeMemFSFile(`/work/${name}`, new Uint8Array(await blob.arrayBuffer()));
    }

    const compiled = await texEngine.compileLaTeX();
    const log = formatLog(result.stderr, result.warnings, compiled.log);
    if (compiled.status !== 0 || !compiled.pdf) {
      throw new Error(log || "PDF compilation failed.");
    }

    return {
      log,
      pdfBlob: new Blob([compiled.pdf], { type: "application/pdf" })
    };
  }

  async function boot() {
    await registerServiceWorker();
    [pandocModule] = await Promise.all([
      import("./pandoc.js"),
      loadPdfTeXScript()
    ]);

    const PdfTeXEngine = window.PdfTeXEngine || window.exports?.PdfTeXEngine;
    if (!PdfTeXEngine) {
      throw new Error("PdfTeXEngine failed to load.");
    }

    texEngine = new PdfTeXEngine();
    await texEngine.loadEngine();
    texEngine.setTexliveEndpoint(TEXLIVE_ENDPOINT);
  }

  function loadSupportFiles() {
    if (!supportFilesPromise) {
      supportFilesPromise = Promise.all(
        SUPPORT_FILES.map(async (name) => [name, await fetchText(name)])
      ).then((entries) => Object.fromEntries(entries));
    }

    return supportFilesPromise;
  }

  return { build, prepare };
}

function createPandocOptions(hidePageNumbers) {
  const variables = {
    "code-block-font-size": "\\footnotesize",
    colorlinks: true,
    urlcolor: "linktextblue",
    linkcolor: "linktextblue",
    citecolor: "linktextblue",
    filecolor: "linktextblue",
    "listings-no-page-break": true,
    "disable-header-and-footer": true,
    paragraphs: true
  };

  if (hidePageNumbers) {
    variables.pagestyle = "empty";
  }

  return {
    filters: ["pdf-fixes.lua"],
    from: "gfm+hard_line_breaks+fenced_divs+tex_math_dollars+yaml_metadata_block",
    "highlight-style": "vscode-light.theme",
    "include-in-header": ["header.tex"],
    "resource-path": [".", "media"],
    standalone: true,
    template: "eisvogel.latex",
    to: "latex",
    variables
  };
}

async function fetchText(name) {
  const response = await fetch(name);
  if (!response.ok) {
    throw new Error(`Unable to load ${name}`);
  }

  return response.text();
}

function loadPdfTeXScript() {
  if (window.PdfTeXEngine || window.exports?.PdfTeXEngine) {
    return Promise.resolve();
  }

  const existing = document.querySelector('script[data-pdftex="true"]');
  if (existing) {
    if (existing.dataset.loaded === "true") {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      existing.addEventListener("load", resolve, { once: true });
      existing.addEventListener("error", reject, { once: true });
    });
  }

  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.dataset.pdftex = "true";
    script.src = "./swiftlatex/PdfTeXEngine.js";
    script.onload = () => {
      script.dataset.loaded = "true";
      resolve();
    };
    script.onerror = () => reject(new Error("Unable to load PdfTeXEngine.js"));
    document.head.appendChild(script);
  });
}

async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) {
    return;
  }

  try {
    await navigator.serviceWorker.register(`./texlive-sw.js?endpoint=${encodeURIComponent(TEXLIVE_ENDPOINT)}`, {
      scope: "./"
    });
  } catch (error) {
    console.warn("Service worker registration failed", error);
  }
}

function formatLog(...chunks) {
  const text = chunks
    .flatMap((chunk) => Array.isArray(chunk) ? chunk : [chunk])
    .map((value) => formatChunk(value))
    .filter(Boolean)
    .join("\n\n")
    .trim();

  return text || "Build failed.";
}

function formatChunk(value) {
  if (!value) {
    return "";
  }

  if (typeof value === "string") {
    return value.trim();
  }

  return JSON.stringify(value, null, 2);
}
