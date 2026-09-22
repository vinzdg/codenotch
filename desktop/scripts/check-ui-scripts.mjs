// Parses the inline <script> of every page in codenotch/ui without running it.
//
// A syntax error anywhere in a page's script stops all of it, and the window
// opens empty with nothing in the log to say why. cargo never reads these
// files, so the Rust build stays green through it: a conflict resolution that
// left a stray function body in settings.html shipped that way in 1.12.0.
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const ui = join(dirname(fileURLToPath(import.meta.url)), '..', 'codenotch', 'ui');
let failed = false;

for (const name of readdirSync(ui).filter(f => f.endsWith('.html'))) {
  const html = readFileSync(join(ui, name), 'utf8');
  const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)];
  blocks.forEach((block, index) => {
    // The line the block starts on, so an error points into the .html itself.
    const lineOffset = html.slice(0, block.index).split('\n').length - 1;
    try {
      // `type="module"` pages would need vm.SourceTextModule; none are modules
      // today, and compiling as a script is what WebView2 does with them.
      new vm.Script(block[1], { filename: `${name} <script> #${index + 1}`, lineOffset });
    } catch (error) {
      failed = true;
      console.error(`${name}: ${error.message}`);
      if (error.stack) console.error(error.stack.split('\n').slice(0, 3).join('\n'));
    }
  });
  console.log(`${name}: ${blocks.length} inline script(s) checked`);
}

process.exit(failed ? 1 : 0);
