// Evaluated once, when the snapshot is made. An isolate started from the snapshot already has this value.
import { eprintln } from 'origine:@std/debug';

export const made = 'made at snapshot time';

export async function main() {
  eprintln('isolate from the restored snapshot prints:', made);
}
