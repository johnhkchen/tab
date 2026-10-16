// Tab's plans and prices. They live in the repo, not in the CMS: the pricing
// page's `plans` block shows exactly these, and editors can move the block but
// can't change a number. The spec (§9) fixes them; `pnpm check:plans` guards them.

export interface Plan {
	/** Card heading. */
	name: string;
	/** The price line, shown in bold with a full stop added. */
	price: string;
	/** What you get, in a sentence or three. */
	description: string;
}

export const plans: readonly Plan[] = [
	{
		name: 'Run it yourself',
		price: 'Free, forever',
		description:
			'Everything Tab does, on your own computer or server. Want it to read your bills? Add your own AI key and pay the AI company directly.',
	},
	{
		name: 'Hosted free',
		price: '$0. No card needed',
		description:
			'Everything in Tab except bill reading, hosted by us. Add bills and forward them, and fill them in yourself.',
	},
	{
		name: 'Plus',
		price: '$10 a year',
		description:
			'Tab reads your bills for you. Forward them to your own Tab address, snap a receipt, or upload a PDF. Have as many groups as you like (a house, a club, a trip), all on one plan.',
	},
	{
		name: 'Pro',
		price: '$24 a year',
		description:
			"Opens later. For landlords and anyone billing other households. Everything in Plus, and: see what each household owes you (or you owe them) in one place, pay back repair costs from there, and split one bill across several properties. Your households don't pay anything.",
	},
];
