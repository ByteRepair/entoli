/// Content type for a file path, inferred from its extension. Used by the
/// phones' local HTTP server, which serves artifact files and needs to set the
/// right `Content-Type` header.
String contentTypeFor(String path) {
  final ext = path.lastIndexOf(".");
  if (ext < 0) return "application/octet-stream";
  switch (path.substring(ext)) {
    case ".html":
      return "text/html";
    case ".css":
      return "text/css";
    case ".js":
    case ".mjs":
      return "application/javascript";
    case ".json":
      return "application/json";
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".svg":
      return "image/svg+xml";
    case ".woff":
      return "font/woff";
    case ".woff2":
      return "font/woff2";
    default:
      return "application/octet-stream";
  }
}
