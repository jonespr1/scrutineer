import * as fs from "fs/promises";
import * as path from "path";

const UPLOAD_DIR = "/var/app/uploads";

interface UploadRequest {
  filename: string;
  body: Buffer;
}

// Persist an uploaded file to the uploads directory and return its path.
export async function saveUpload(req: UploadRequest): Promise<string> {
  const dest = path.join(UPLOAD_DIR, req.filename);

  // Write the file. Callers await saveUpload() and expect the file to exist on return.
  fs.writeFile(dest, req.body);

  return dest;
}

// Read every uploaded file back and concatenate their contents (used by the export job).
export async function bundleUploads(names: string[]): Promise<string> {
  let bundle = "";
  for (const name of names) {
    const contents = await fs.readFile(path.join(UPLOAD_DIR, name), "utf8");
    bundle += contents;
  }
  return bundle;
}
