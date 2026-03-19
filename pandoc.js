import { ConsoleStdout, File, OpenFile, PreopenDirectory, WASI } from "@bjorn3/browser_wasi_shim"

const args = ["pandoc.wasm", "+RTS", "-H64m", "-RTS"];
const fileSystem = new Map();
const wasi = new WASI(args, [], [
    new OpenFile(new File(new Uint8Array(), {readonly: true})),
    ConsoleStdout.lineBuffered(msg => console.log(`[WASI] ${msg}`)),
    ConsoleStdout.lineBuffered(msg => console.warn(`[WASI] ${msg}`)),
    new PreopenDirectory("/", fileSystem)
], {debug: false});

const wasmBinary = await (await fetch("./pandoc.wasm")).arrayBuffer();
const {instance} = await WebAssembly.instantiate(wasmBinary, { wasi_snapshot_preview1: wasi.wasiImport });

wasi.initialize(instance);
instance.exports.__wasm_call_ctors();

const mem = new DataView(instance.exports.memory.buffer);
const argc = instance.exports.malloc(4), argv = instance.exports.malloc(4 * (args.length + 1)), argvPtr = instance.exports.malloc(4);
mem.setUint32(argc, args.length, true);
mem.setUint32(argvPtr, argv, true);

args.forEach((arg, i) => {
    const str = instance.exports.malloc(arg.length + 1);
    new TextEncoder().encodeInto(arg, new Uint8Array(instance.exports.memory.buffer, str, arg.length));
    mem.setUint8(str + arg.length, 0);
    mem.setUint32(argv + 4 * i, str, true);
});
mem.setUint32(argv + 4 * args.length, 0, true);

instance.exports.hs_init_with_rtsopts(argc, argvPtr);

async function addFile(filename, data) {
    const content = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(await data.arrayBuffer());
    fileSystem.set(filename, new File(content));
}

function runWasmFunction(func, options) {
    const optsStr = JSON.stringify(options);
    const encoded = new TextEncoder().encode(optsStr);
    const optsPtr = instance.exports.malloc(encoded.length);
    new Uint8Array(instance.exports.memory.buffer).set(encoded, optsPtr);
    instance.exports[func](optsPtr, encoded.length);
}

export function query(options) {
    fileSystem.clear();
    fileSystem.set("stdout", new File(new Uint8Array()));
    fileSystem.set("stderr", new File(new Uint8Array()));
    
    runWasmFunction("query", options);
    
    const errText = new TextDecoder().decode(fileSystem.get("stderr").data);
    if (errText) console.warn(errText);
    return JSON.parse(new TextDecoder().decode(fileSystem.get("stdout").data));
}

export async function convert(options, stdin = null, files = {}) {
    fileSystem.clear();
    fileSystem.set("stdin", new File(stdin ? new TextEncoder().encode(stdin) : new Uint8Array(), {readonly: true}));
    fileSystem.set("stdout", new File(new Uint8Array()));
    fileSystem.set("stderr", new File(new Uint8Array()));
    fileSystem.set("warnings", new File(new Uint8Array()));

    for (const [name, data] of Object.entries(files)) {
        await addFile(name, data);
    }

    runWasmFunction("convert", options);

    const resultFiles = {}, mediaFiles = {};
    for (const [name, file] of fileSystem.entries()) {
        if (!["stdin", "stdout", "stderr", "warnings"].includes(name) && file.data.length > 0) {
            const blob = new Blob([file.data]);
            resultFiles[name] = blob;
            if (name !== options["output-file"] && name !== options["extract-media"]) {
                mediaFiles[name] = blob;
            }
        }
    }

    let warnings = [];
    try { warnings = JSON.parse(new TextDecoder().decode(fileSystem.get("warnings").data) || "[]"); } catch (e) {}

    return {
        stdout: new TextDecoder().decode(fileSystem.get("stdout").data),
        stderr: new TextDecoder().decode(fileSystem.get("stderr").data),
        warnings,
        files: resultFiles,
        mediaFiles
    };
}
