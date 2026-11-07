const fs = require('fs');
const path = require('path');
const solc = require(path.resolve(__dirname, '../../.audit-tools/venus-oracle-build/node_modules/solc'));
let input = '';
process.stdin.on('data', d => input += d);
process.stdin.on('end', () => {
  const args = process.argv.slice(2);
  if (args.includes('--version')) {
    console.log(solc.version());
    return;
  }
  const parsed = JSON.parse(input);
  const output = JSON.parse(solc.compile(JSON.stringify(parsed), {
    import: file => {
      const roots = [
        process.cwd(),
        path.resolve(__dirname, '..'),
        path.resolve(__dirname, '../../.audit-tools/venus-oracle-build/node_modules'),
        path.resolve(__dirname, '../../lib')
      ];
      for (const root of roots) {
        try { return { contents: fs.readFileSync(path.join(root, file), 'utf8') }; } catch (_) {}
      }
      return { error: `Unable to resolve ${file}` };
    }
  }));
  console.log(JSON.stringify(output));
});
