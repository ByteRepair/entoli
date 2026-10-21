// The browser's Linux, off the page's thread: v86 runs here, so an emulated
// CPU busy for minutes never stalls a frame. The page and this worker speak in
// two kinds of message: the mux's serial lines, and the guest's 9p requests,
// which the page answers from the app's own files. See "The browser's Linux"
// in lib/data/web/AGENTS.md.
"use strict";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
let emulator = null;
let reply9p = null;

function lines(port, type) {
  let pending = [];
  emulator.add_listener(`serial${port}-output-byte`, (byte) => {
    if (byte !== 10) {
      pending.push(byte);
      return;
    }
    postMessage({ type, line: decoder.decode(new Uint8Array(pending)) });
    pending = [];
  });
}

function boot({ image, cmdline, memory, disk }) {
  importScripts(image + "libv86.js");
  emulator = new self.V86({
    wasm_path: image + "v86.wasm",
    bios: { url: image + "seabios.bin" },
    vga_bios: { url: image + "vgabios.bin" },
    bzimage: { url: image + "kernel" },
    initrd: { url: image + "initrd" },
    hda: {
      url: image + "disk/disk.img.zst",
      async: true,
      size: disk.bytes,
      fixed_chunk_size: disk.chunk,
      use_parts: true,
    },
    cmdline,
    memory_size: memory,
    uart1: true,
    autostart: true,
    disable_keyboard: true,
    disable_mouse: true,
    disable_speaker: true,
    filesystem: {
      handle9p(request, reply) {
        // One function answers every tag: v86 finds the request a reply is
        // for by the tag inside it.
        reply9p = reply;
        postMessage({ type: "9p", message: request }, [request.buffer]);
      },
    },
  });
  emulator.add_listener("download-error", (e) =>
    postMessage({ type: "error", message: `could not fetch ${e.file_name}` }));
  lines(0, "log");
  lines(1, "line");
}

onmessage = ({ data }) => {
  switch (data.type) {
    case "boot":
      try {
        boot(data);
      } catch (e) {
        postMessage({ type: "error", message: String(e) });
      }
      break;
    case "send":
      // A ping can arrive before the boot has made anything to send it to.
      emulator?.serial_send_bytes(1, encoder.encode(data.line + "\n"));
      break;
    case "9p":
      reply9p(data.message);
      break;
    case "stop":
      emulator.destroy().finally(() => close());
      break;
  }
};
