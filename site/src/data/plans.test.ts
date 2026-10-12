// Run with `pnpm check:plans` (node's built-in test runner; node strips the types).
// A price change has to change this test too, on purpose.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { plans } from './plans.ts';

const priceOf = (name: string) => plans.find((plan) => plan.name === name)?.price;

test('the four plans, in order', () => {
	assert.deepEqual(
		plans.map((plan) => plan.name),
		['Run it yourself', 'Hosted free', 'Plus', 'Pro'],
	);
});

test('prices match the spec', () => {
	assert.equal(priceOf('Run it yourself'), 'Free, forever');
	assert.equal(priceOf('Hosted free'), '$0. No card needed');
	assert.equal(priceOf('Plus'), '$10 a year');
	assert.equal(priceOf('Pro'), '$24 a year');
});
