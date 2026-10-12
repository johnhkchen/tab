// Puts the landing and pricing pages from seed/seed.json into the local
// database of a running dev server (`pnpm dev`). Safe to run again: EmDash
// skips anything that already exists and never overwrites edits.
//
// It uses EmDash's dev-only setup shortcut, which also signs in a local
// "Dev Admin" so /_emdash/admin opens without a password. It refuses to run
// on a production build. Production sites get their pages from the setup
// wizard instead (choose to include the sample content).

const base = process.env.SITE_URL ?? `http://localhost:${process.env.PORT ?? 4321}`;

export async function seed(url = base) {
	const res = await fetch(new URL('/_emdash/api/setup/dev-bypass', url), { method: 'POST' });
	if (!res.ok) {
		throw new Error(`seeding failed: ${res.status} ${await res.text()}`);
	}
	console.log(`seeded pages into ${url}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
	seed().catch((error) => {
		console.error(error.message);
		console.error(`Is the dev server running at ${base}? Start it with \`mise run site:dev\`.`);
		process.exit(1);
	});
}
