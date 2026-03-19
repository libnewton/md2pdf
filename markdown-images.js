const MEDIA_DIR = "media";
const MAX_BASE_LENGTH = 32;
const ASSET_DRAG_TYPE = "application/x-md2pdf-asset";
const FALLBACK_PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WHZpG0AAAAASUVORK5CYII=";
const DB_NAME = "md2pdf-image-library";
const DB_STORE = "assets";
const DB_VERSION = 1;
const LATEX_IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "pdf"]);

export function createImageStore({ onChange = () => {} } = {}) {
  const assets = new Map();
  const unresolved = new Map();
  const aliases = new Map();
  const remoteAssets = new Map();
  const usedNames = new Set();
  let sequence = 0;

  const notify = () => onChange(getSnapshot());
  const persist = () => {
    void persistAssets(Array.from(assets.values()).map(serializeAssetRecord)).catch((error) => {
      console.warn("Unable to persist image library", error);
    });
  };

  async function addFiles(files) {
    const incoming = files.filter(isImageFile);
    const addedAssets = [];

    for (const file of incoming) {
      const asset = await createStoredAsset({
        blob: file,
        name: file.name || defaultNameForMime(file.type),
        source: "upload"
      });
      storeAsset(asset, { primaryAlias: asset.originalName });
      addedAssets.push(asset);
    }

    if (incoming.length) {
      persist();
      notify();
    }

    return {
      assets: addedAssets,
      count: incoming.length
    };
  }

  function assignAlias(unresolvedId, assetId) {
    const entry = Array.from(unresolved.values()).find((item) => item.id === unresolvedId);
    const asset = assets.get(assetId);
    if (!entry || !asset) {
      return;
    }

    const aliasKey = normalizeFilename(entry.aliasName);
    aliases.set(aliasKey, asset.id);
    if (!asset.aliases.includes(entry.aliasName)) {
      asset.aliases.unshift(entry.aliasName);
    }

    persist();
    revokePreview(entry.previewUrl);
    unresolved.delete(aliasKey);
    notify();
  }

  async function removeEntry(id) {
    if (assets.has(id)) {
      const asset = assets.get(id);
      revokePreview(asset.previewUrl);
      assets.delete(id);

      for (const [key, value] of aliases.entries()) {
        if (value === id) {
          aliases.delete(key);
        }
      }

      for (const [key, value] of remoteAssets.entries()) {
        if (value === id) {
          remoteAssets.delete(key);
        }
      }

      persist();
      notify();
      return true;
    }

    for (const [key, entry] of unresolved.entries()) {
      if (entry.id === id) {
        revokePreview(entry.previewUrl);
        unresolved.delete(key);
        notify();
        return true;
      }
    }

    return false;
  }

  async function reset() {
    dispose();
    assets.clear();
    unresolved.clear();
    aliases.clear();
    remoteAssets.clear();
    usedNames.clear();
    sequence = 0;
    await persistAssets([]);
    notify();
  }

  async function restore() {
    const records = await loadStoredAssets();
    for (const record of records) {
      const asset = await restoreAssetRecord(record);
      sequence = Math.max(sequence, extractSequence(asset.id), asset.createdAt);
      usedNames.add(asset.generatedName);
      assets.set(asset.id, asset);

      for (const alias of asset.aliases) {
        aliases.set(normalizeFilename(alias), asset.id);
      }

      if (asset.remoteUrl) {
        remoteAssets.set(asset.remoteUrl, asset.id);
      }
    }

    if (records.length) {
      persist();
    }

    notify();
  }

  async function resolveMarkdown(markdown) {
    const normalizedMarkdown = normalizeLegacyImageSizing(markdown);
    const references = collectImageReferences(normalizedMarkdown);
    const activeMissing = new Set();
    const replacements = [];
    const mediaFiles = {};
    const resolutions = new Map();

    for (const reference of references) {
      const cacheKey = `${reference.kind}:${reference.url}`;
      let resolution = resolutions.get(cacheKey);
      if (!resolution) {
        resolution = await resolveReference(reference);
        resolutions.set(cacheKey, resolution);
      }

      replacements.push({
        start: reference.start,
        end: reference.end,
        value: resolution.path
      });

      mediaFiles[resolution.path] = resolution.blob;
      if (resolution.missingKey) {
        activeMissing.add(resolution.missingKey);
      }
    }

    pruneMissing(activeMissing);
    notify();

    return {
      markdown: applyReplacements(normalizedMarkdown, replacements),
      mediaFiles
    };
  }

  function getSnapshot() {
    return {
      assets: Array.from(assets.values()).sort(byCreatedAt),
      unresolved: Array.from(unresolved.values()).sort(byCreatedAt)
    };
  }

  function dispose() {
    for (const asset of assets.values()) {
      revokePreview(asset.previewUrl);
    }

    for (const entry of unresolved.values()) {
      revokePreview(entry.previewUrl);
    }
  }

  async function resolveReference(reference) {
    if (reference.url.startsWith("data:")) {
      const blob = dataUrlToBlob(reference.url);
      return buildEphemeralResolution(blob, reference.inferredName || defaultNameForMime(blob.type), reference.url);
    }

    if (reference.url.startsWith("blob:")) {
      const blob = await fetchImageBlob(reference.url);
      return buildEphemeralResolution(blob, reference.inferredName || defaultNameForMime(blob.type), reference.url);
    }

    try {
      const fetched = await fetchImageAsset(reference.url, reference.inferredName);
      return assetResolution(fetched);
    } catch (_) {
      const aliasKey = normalizeFilename(reference.inferredName);
      const assetId = aliases.get(aliasKey);
      if (assetId) {
        return assetResolution(assets.get(assetId));
      }

      const missing = await ensureMissing(reference);
      return {
        blob: missing.blob,
        missingKey: aliasKey,
        path: toMediaPath(missing.generatedName)
      };
    }
  }

  async function fetchImageAsset(url, fallbackName) {
    if (remoteAssets.has(url)) {
      return assets.get(remoteAssets.get(url));
    }

    const response = await fetch(url, {
      credentials: "omit",
      mode: "cors"
    });

    if (!response.ok) {
      throw new Error(`Unable to fetch ${url}`);
    }

    const type = response.headers.get("content-type") || "";
    if (!type.startsWith("image/")) {
      throw new Error(`Unsupported image type for ${url}`);
    }

    const blob = await response.blob();
    const resolvedUrl = response.url || url;
    const asset = await createStoredAsset({
      blob,
      name: inferFilename(resolvedUrl, fallbackName, type),
      remoteUrl: url,
      source: "download"
    });
    storeAsset(asset, { primaryAlias: asset.originalName });
    remoteAssets.set(url, asset.id);
    persist();
    return asset;
  }

  async function createStoredAsset({ blob, name, remoteUrl = "", source }) {
    const normalized = await normalizeAssetBlob(blob, name || defaultNameForMime(blob.type));
    const originalName = ensureExtension(normalized.name, normalized.blob.type);
    return {
      id: `asset-${++sequence}`,
      aliases: [originalName],
      blob: normalized.blob,
      createdAt: sequence,
      generatedName: makeUniqueFilename(originalName, `${source}:${originalName}:${sequence}`),
      originalName,
      previewUrl: URL.createObjectURL(normalized.blob),
      remoteUrl,
      source
    };
  }

  function storeAsset(asset, { primaryAlias }) {
    assets.set(asset.id, asset);
    aliases.set(normalizeFilename(primaryAlias), asset.id);
  }

  async function ensureMissing(reference) {
    const aliasName = reference.inferredName || defaultNameForMime("image/png");
    const aliasKey = normalizeFilename(aliasName);
    const existing = unresolved.get(aliasKey);
    if (existing) {
      existing.sourceUrl = reference.url;
      return existing;
    }

    const blob = await createMissingImage(aliasName);
    const entry = {
      aliasName,
      blob,
      createdAt: ++sequence,
      generatedName: makeUniqueFilename(`error-${aliasName}`, `missing:${aliasName}`),
      id: `missing-${sequence}`,
      previewUrl: URL.createObjectURL(blob),
      sourceUrl: reference.url
    };

    unresolved.set(aliasKey, entry);
    return entry;
  }

  function pruneMissing(activeMissing) {
    for (const [key, entry] of unresolved.entries()) {
      if (activeMissing.has(key)) {
        continue;
      }

      revokePreview(entry.previewUrl);
      unresolved.delete(key);
    }
  }

  function buildEphemeralResolution(blob, fallbackName, key) {
    const filename = makeUniqueFilename(fallbackName, `ephemeral:${key}`);
    return {
      blob,
      path: toMediaPath(filename)
    };
  }

  function assetResolution(asset) {
    return {
      blob: asset.blob,
      path: toMediaPath(asset.generatedName)
    };
  }

  function makeUniqueFilename(name, key) {
    const clean = ensureExtension(name, "image/png");
    const { base, ext } = splitFilename(clean);
    const stem = slugify(base).slice(0, MAX_BASE_LENGTH) || "image";
    const hash = hashText(key).slice(0, 8);
    let candidate = `${stem}-${hash}.${ext}`;
    let counter = 1;

    while (usedNames.has(candidate)) {
      counter += 1;
      candidate = `${stem}-${hash}-${counter}.${ext}`;
    }

    usedNames.add(candidate);
    return candidate;
  }

  return {
    addFiles,
    assignAlias,
    dispose,
    getSnapshot,
    removeEntry,
    reset,
    restore,
    resolveMarkdown
  };
}

function applyReplacements(markdown, replacements) {
  return replacements
    .sort((left, right) => right.start - left.start)
    .reduce((output, replacement) => {
      return output.slice(0, replacement.start) + replacement.value + output.slice(replacement.end);
    }, markdown);
}

function normalizeLegacyImageSizing(markdown) {
  return markdown.replace(/!\[([^\]]*)]\(([^()\s]+)\s+=\s*(\d+)x(\d*)\s*\)/g, (_, alt, url, width, height) => {
    const attrs = [`width=${width}px`];
    if (height) {
      attrs.push(`height=${height}px`);
    }

    return `![${alt}](${url}){ ${attrs.join(" ")} }`;
  });
}

function collectImageReferences(markdown) {
  const definitions = collectReferenceDefinitions(markdown);
  const references = [];

  for (let index = 0; index < markdown.length; index += 1) {
    if (markdown[index] !== "!" || markdown[index + 1] !== "[") {
      continue;
    }

    const alt = parseBracket(markdown, index + 1);
    if (!alt) {
      continue;
    }

    const marker = markdown[alt.nextIndex];
    if (marker === "(") {
      const inlineRef = parseInlineImage(markdown, alt.nextIndex);
      if (inlineRef) {
        references.push({
          kind: "inline",
          inferredName: inferFilename(inlineRef.url, "image.png"),
          start: inlineRef.start,
          end: inlineRef.end,
          url: inlineRef.url
        });
      }
    }

    if (marker === "[") {
      const label = parseBracket(markdown, alt.nextIndex);
      if (!label) {
        continue;
      }

      const key = normalizeReferenceKey(label.content || alt.content);
      const url = definitions.get(key);
      if (!url) {
        continue;
      }

      references.push({
        kind: "reference",
        inferredName: inferFilename(url, "image.png"),
        start: definitions.get(`${key}:start`),
        end: definitions.get(`${key}:end`),
        url
      });
    }
  }

  const htmlPattern = /<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>/gi;
  for (const match of markdown.matchAll(htmlPattern)) {
    const tag = match[0];
    const src = match[2];
    const prefix = tag.indexOf(src);
    const start = match.index + prefix;
    references.push({
      kind: "html",
      inferredName: inferFilename(src, "image.png"),
      start,
      end: start + src.length,
      url: src
    });
  }

  return references.filter(isValidReference).sort((left, right) => left.start - right.start);
}

function collectReferenceDefinitions(markdown) {
  const definitions = new Map();
  const pattern = /^[ \t]{0,3}\[([^\]]+)]\:[ \t]*(?:<([^>\n]+)>|(\S+))/gm;

  for (const match of markdown.matchAll(pattern)) {
    const label = normalizeReferenceKey(match[1]);
    const url = match[2] || match[3] || "";
    const offset = match[0].lastIndexOf(url);
    definitions.set(label, url);
    definitions.set(`${label}:start`, match.index + offset);
    definitions.set(`${label}:end`, match.index + offset + url.length);
  }

  return definitions;
}

function parseInlineImage(markdown, openIndex) {
  let cursor = openIndex + 1;
  while (cursor < markdown.length && /\s/.test(markdown[cursor])) {
    cursor += 1;
  }

  if (markdown[cursor] === "<") {
    const end = markdown.indexOf(">", cursor + 1);
    if (end === -1) {
      return null;
    }

    return {
      start: cursor + 1,
      end,
      url: markdown.slice(cursor + 1, end)
    };
  }

  const start = cursor;
  let depth = 0;
  while (cursor < markdown.length) {
    const char = markdown[cursor];
    if (char === "\\") {
      cursor += 2;
      continue;
    }

    if (char === "(") {
      depth += 1;
      cursor += 1;
      continue;
    }

    if (char === ")") {
      if (depth === 0) {
        break;
      }

      depth -= 1;
      cursor += 1;
      continue;
    }

    if (/\s/.test(char) && depth === 0) {
      break;
    }

    cursor += 1;
  }

  if (cursor === start) {
    return null;
  }

  return {
    start,
    end: cursor,
    url: markdown.slice(start, cursor)
  };
}

function parseBracket(markdown, startIndex) {
  if (markdown[startIndex] !== "[") {
    return null;
  }

  let depth = 0;
  for (let index = startIndex; index < markdown.length; index += 1) {
    const char = markdown[index];
    if (char === "\\") {
      index += 1;
      continue;
    }

    if (char === "[") {
      depth += 1;
    } else if (char === "]") {
      depth -= 1;
      if (depth === 0) {
        return {
          content: markdown.slice(startIndex + 1, index),
          nextIndex: index + 1
        };
      }
    }
  }

  return null;
}

async function fetchImageBlob(url) {
  const response = await fetch(url, { credentials: "omit", mode: "cors" });
  if (!response.ok) {
    throw new Error(`Unable to fetch ${url}`);
  }

  const type = response.headers.get("content-type") || "";
  if (!type.startsWith("image/")) {
    throw new Error(`Unsupported image type for ${url}`);
  }

  return response.blob();
}

function dataUrlToBlob(url) {
  const [header, payload] = url.split(",", 2);
  const mime = header.match(/^data:([^;,]+)/)?.[1] || "application/octet-stream";
  if (!header.includes(";base64")) {
    return new Blob([decodeURIComponent(payload || "")], { type: mime });
  }

  const binary = atob(payload || "");
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return new Blob([bytes], { type: mime });
}

async function createMissingImage(name) {
  const canvas = document.createElement("canvas");
  canvas.width = 720;
  canvas.height = 400;
  const context = canvas.getContext("2d");
  if (!context) {
    return dataUrlToBlob(FALLBACK_PNG_DATA_URL);
  }

  const label = truncateText(name, 30);

  context.fillStyle = "#fff7ed";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.strokeStyle = "#ea580c";
  context.lineWidth = 10;
  context.strokeRect(20, 20, canvas.width - 40, canvas.height - 40);
  context.fillStyle = "#9a3412";
  context.font = "bold 36px sans-serif";
  context.fillText("Missing image", 52, 110);
  context.font = "24px monospace";
  wrapText(context, label, 52, 175, 610, 34);
  context.font = "20px sans-serif";
  context.fillText("Add a matching file or drop a library image onto this card.", 52, 320);

  return new Promise((resolve) => {
    canvas.toBlob((blob) => resolve(blob || dataUrlToBlob(canvas.toDataURL("image/png"))), "image/png");
  });
}

function wrapText(context, text, x, y, maxWidth, lineHeight) {
  const words = text.split(/\s+/);
  let line = "";
  let row = y;

  for (const word of words) {
    const next = line ? `${line} ${word}` : word;
    if (context.measureText(next).width > maxWidth && line) {
      context.fillText(line, x, row);
      line = word;
      row += lineHeight;
      continue;
    }

    line = next;
  }

  if (line) {
    context.fillText(line, x, row);
  }
}

function inferFilename(url, fallbackName = "image.png", mime = "") {
  if (url.startsWith("data:")) {
    return ensureExtension(fallbackName, mime);
  }

  try {
    const parsed = new URL(url, window.location.href);
    const raw = decodeURIComponent(parsed.pathname.split("/").pop() || "");
    return ensureExtension(raw || fallbackName, mime);
  } catch (_) {
    return ensureExtension(url.split("/").pop() || fallbackName, mime);
  }
}

function ensureExtension(name, mime) {
  const trimmed = sanitizeFilename(name || "image");
  const preferredExt = preferredExtensionFromMime(mime);
  const { base, ext } = splitFilename(trimmed);

  if (ext && (LATEX_IMAGE_EXTENSIONS.has(ext) || !preferredExt)) {
    return `${base}.${ext}`;
  }

  if (preferredExt) {
    return `${base || "image"}.${preferredExt}`;
  }

  return `${base || "image"}.png`;
}

async function normalizeAssetBlob(blob, name) {
  const mime = String(blob?.type || "").toLowerCase().split(";")[0].trim();
  const safeName = ensureExtension(name, mime);

  if (!mime || mime === "image/png" || mime === "image/jpeg" || mime === "application/pdf") {
    return { blob, name: safeName };
  }

  if (mime.startsWith("image/")) {
    const pngBlob = await convertBlobToPng(blob);
    return {
      blob: pngBlob,
      name: `${splitFilename(safeName).base || "image"}.png`
    };
  }

  return { blob, name: safeName };
}

async function convertBlobToPng(blob) {
  if (typeof createImageBitmap !== "function") {
    return convertBlobToPngWithImage(blob);
  }

  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const context = canvas.getContext("2d");
  if (!context) {
    bitmap.close();
    throw new Error("Unable to create canvas for image conversion.");
  }

  context.drawImage(bitmap, 0, 0);
  bitmap.close();

  return new Promise((resolve, reject) => {
    canvas.toBlob((pngBlob) => {
      if (!pngBlob) {
        reject(new Error("Unable to convert image to PNG."));
        return;
      }
      resolve(pngBlob);
    }, "image/png");
  });
}

async function convertBlobToPngWithImage(blob) {
  const objectUrl = URL.createObjectURL(blob);

  try {
    const image = await new Promise((resolve, reject) => {
      const element = new Image();
      element.onload = () => resolve(element);
      element.onerror = () => reject(new Error("Unable to decode image."));
      element.src = objectUrl;
    });

    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth || image.width;
    canvas.height = image.naturalHeight || image.height;
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Unable to create canvas for image conversion.");
    }

    context.drawImage(image, 0, 0);
    return new Promise((resolve, reject) => {
      canvas.toBlob((pngBlob) => {
        if (!pngBlob) {
          reject(new Error("Unable to convert image to PNG."));
          return;
        }
        resolve(pngBlob);
      }, "image/png");
    });
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

function extensionFromMime(mime) {
  return preferredExtensionFromMime(mime) || mime.split("/")[1]?.replace(/[^a-z0-9]/gi, "") || "png";
}

function splitFilename(name) {
  const match = String(name).match(/^(.*?)(?:\.([^.]+))?$/);
  return {
    base: match?.[1] || "image",
    ext: (match?.[2] || "").toLowerCase()
  };
}

function sanitizeFilename(name) {
  return String(name || "image")
    .trim()
    .replace(/[?#].*$/, "")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "image";
}

function preferredExtensionFromMime(mime) {
  const normalized = String(mime || "").toLowerCase().split(";")[0].trim();
  if (normalized === "image/jpeg") {
    return "jpg";
  }
  if (normalized === "image/png") {
    return "png";
  }
  if (normalized === "application/pdf") {
    return "pdf";
  }
  if (normalized.startsWith("image/")) {
    return "png";
  }
  return "";
}

function slugify(value) {
  return String(value)
    .normalize("NFKD")
    .replace(/[^\x00-\x7F]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function normalizeFilename(value) {
  return String(value || "")
    .trim()
    .replace(/^<|>$/g, "")
    .toLowerCase();
}

function normalizeReferenceKey(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
}

function truncateText(value, length) {
  return value.length > length ? `${value.slice(0, length - 1)}...` : value;
}

function hashText(input) {
  let hash = 2166136261;
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function defaultNameForMime(mime) {
  return `image.${extensionFromMime(mime)}`;
}

function isImageFile(file) {
  return Boolean(file) && ((file.type || "").startsWith("image/") || /\.(png|jpe?g|gif|svg|webp|bmp)$/i.test(file.name || ""));
}

function isValidReference(reference) {
  return Boolean(reference.url) && reference.end > reference.start;
}

function toMediaPath(name) {
  return `${MEDIA_DIR}/${name}`;
}

function byCreatedAt(left, right) {
  return left.createdAt - right.createdAt;
}

function revokePreview(url) {
  if (url) {
    URL.revokeObjectURL(url);
  }
}

function serializeAssetRecord(asset) {
  return {
    aliases: asset.aliases,
    blob: asset.blob,
    createdAt: asset.createdAt,
    generatedName: asset.generatedName,
    id: asset.id,
    originalName: asset.originalName,
    remoteUrl: asset.remoteUrl || "",
    source: asset.source
  };
}

async function restoreAssetRecord(record) {
  const normalized = await normalizeAssetBlob(record.blob, record.originalName || record.generatedName);
  const normalizedName = ensureExtension(record.generatedName || record.originalName, normalized.blob?.type || "");
  const originalName = ensureExtension(record.originalName, normalized.blob?.type || "");
  const aliases = Array.isArray(record.aliases) && record.aliases.length ? record.aliases : [record.originalName];
  return {
    aliases: [originalName, ...aliases.filter((alias) => alias && alias !== record.originalName && alias !== originalName)],
    blob: normalized.blob,
    createdAt: Number(record.createdAt) || 0,
    generatedName: normalizedName,
    id: record.id,
    originalName,
    previewUrl: URL.createObjectURL(normalized.blob),
    remoteUrl: record.remoteUrl || "",
    source: record.source || "upload"
  };
}

function extractSequence(id) {
  const match = String(id).match(/(\d+)$/);
  return match ? Number(match[1]) : 0;
}

async function persistAssets(records) {
  if (!("indexedDB" in window)) {
    return;
  }

  const db = await openImageLibraryDb();
  await new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, "readwrite");
    const store = transaction.objectStore(DB_STORE);
    store.clear();

    for (const record of records) {
      store.put(record);
    }

    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

async function loadStoredAssets() {
  if (!("indexedDB" in window)) {
    return [];
  }

  const db = await openImageLibraryDb();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, "readonly");
    const store = transaction.objectStore(DB_STORE);
    const request = store.getAll();
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
}

let imageLibraryDbPromise = null;

function openImageLibraryDb() {
  if (!imageLibraryDbPromise) {
    imageLibraryDbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(DB_STORE)) {
          db.createObjectStore(DB_STORE, { keyPath: "id" });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => {
        imageLibraryDbPromise = null;
        reject(request.error);
      };
    });
  }

  return imageLibraryDbPromise;
}

export { ASSET_DRAG_TYPE };
