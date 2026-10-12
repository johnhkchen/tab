// `pnpm dev`: start Astro's dev server (local D1 and R2 in .wrangler/), wait
// for it to answer, then apply seed/seed.json so / and /pricing have pages.
// Extra arguments go to `astro dev`, e.g. `pnpm dev --port 48321`.
// (Under a coding agent, `astro dev` moves itself to the background and
// exits; this script still seeds, then exits too. Stop it with `astro dev stop`.)
import { spawn } from 'node:child_process';
import { seed } from './seed.mjs';

const args = process.argv.slice(2);
const portFlag = args.indexOf('--port');
const port = portFlag >= 0 ? args[portFlag + 1] : (process.env.PORT ?? '4321');
if (portFlag < 0) args.push('--port', port);
const url = `http://localhost:${port}`;

let astroExit = null;
const astro = spawn('astro', ['dev', ...args], { stdio: 'inherit' });
for (const signal of ['SIGINT', 'SIGTERM']) {
	process.on(signal, () => astro.kill(signal));
}
astro.on('exit', (code) => {
	astroExit = code ?? 0;
	if (astroExit !== 0) process.exit(astroExit);
});

async function waitForServer() {
	for (let tries = 0; tries < 120; tries++) {
		try {
			await fetch(url);
			return true;
		} catch {
			await new Promise((resolve) => setTimeout(resolve, 1000));
		}
	}
	return false;
}

if (await waitForServer()) {
	try {
		await seed(url);
	} catch (error) {
		console.error(error.message);
	}
} else {
	console.error(`The dev server didn't answer at ${url}, so the pages weren't seeded. Run \`pnpm seed\` once it's up.`);
}
if (astroExit !== null) process.exit(astroExit);
