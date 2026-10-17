#!/usr/bin/env node
// Validates every GraphQL operation in src/GraphQL against Linear's public schema.
//
// Usage:
//   npm ci --prefix tools
//   node tools/validate-graphql.mjs
//
// Set LINEAR_SCHEMA_PATH to validate against a local schema file instead of
// downloading the latest one from the Linear SDK repository.

import { readFileSync, readdirSync } from 'node:fs';
import { basename, dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSchema, parse, validate, NoDeprecatedCustomRule, Kind } from 'graphql';

const SCHEMA_URL = 'https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql';
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const graphQLRoot = join(repoRoot, 'src', 'GraphQL');

// Same rule as Get-LinearGraphQLDocument: a spread that is not an inline fragment.
const spreadPattern = /(?<!\.)\.\.\.\s*(?!on\b)([_A-Za-z][_0-9A-Za-z]*)/g;

async function loadSchemaSource() {
  if (process.env.LINEAR_SCHEMA_PATH) {
    return readFileSync(process.env.LINEAR_SCHEMA_PATH, 'utf8');
  }
  const response = await fetch(SCHEMA_URL);
  if (!response.ok) {
    throw new Error(`Could not download the Linear schema (${response.status} ${response.statusText}).`);
  }
  return response.text();
}

function listGraphQLFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) return listGraphQLFiles(fullPath);
    return entry.name.endsWith('.graphql') ? [fullPath] : [];
  });
}

function assemble(text, fragments) {
  const included = new Set();
  const queue = [text];
  const parts = [text.trim()];
  while (queue.length > 0) {
    const current = queue.shift();
    for (const match of current.matchAll(spreadPattern)) {
      const name = match[1];
      if (included.has(name)) continue;
      if (!fragments.has(name)) throw new Error(`Unknown fragment '${name}'.`);
      included.add(name);
      parts.push(fragments.get(name).trim());
      queue.push(fragments.get(name));
    }
  }
  return parts.join('\n\n');
}

async function main() {
  const schema = buildSchema(await loadSchemaSource(), { assumeValidSDL: true });
  const files = listGraphQLFiles(graphQLRoot);
  const fragments = new Map();
  const operations = [];
  const problems = [];
  let warnings = 0;

  for (const file of files) {
    const text = readFileSync(file, 'utf8');
    const name = basename(file, '.graphql');
    const definitions = parse(text).definitions;
    if (definitions.length !== 1) {
      problems.push(`${relative(repoRoot, file)}: expected exactly one definition per file.`);
      continue;
    }
    const definition = definitions[0];
    if (definition.name?.value !== name) {
      problems.push(`${relative(repoRoot, file)}: definition name '${definition.name?.value}' must match the file name '${name}'.`);
    }
    if (definition.kind === Kind.FRAGMENT_DEFINITION) {
      fragments.set(name, text);
    } else {
      operations.push({ file, name, text });
    }
  }

  for (const operation of operations) {
    const label = relative(repoRoot, operation.file);
    let document;
    try {
      document = parse(assemble(operation.text, fragments));
    } catch (error) {
      problems.push(`${label}: ${error.message}`);
      continue;
    }
    for (const error of validate(schema, document)) {
      problems.push(`${label}: ${error.message}`);
    }
    for (const warning of validate(schema, document, [NoDeprecatedCustomRule])) {
      warnings += 1;
      console.warn(`warning ${label}: ${warning.message}`);
    }
    console.log(`checked ${label}`);
  }

  if (problems.length > 0) {
    console.error(`\n${problems.length} problem(s) found:`);
    for (const problem of problems) console.error(`  - ${problem}`);
    process.exit(1);
  }
  console.log(`\nAll ${operations.length} operation(s) are valid against the Linear schema (${warnings} deprecation warning(s)).`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
