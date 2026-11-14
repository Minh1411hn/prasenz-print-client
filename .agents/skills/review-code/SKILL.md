---
name: code-review
description: Performs a comprehensive code review focusing on code quality, project conventions, potential bugs, edge cases, and impact analysis on existing flows. Use when user says "review my code", "check my code", "prepare for PR", "review this commit", "review commit <hash>", or asks to inspect changes between branches/commits.
---

# Code Review

Perform a deep, static code review of proposed changes to ensure high code quality, adherence to prasenz-core engineering conventions, absence of bugs, and zero unintended side effects on existing features.

## Strict Environment Restrictions

- NEVER run `npm run dev`, `npm run build`, `nuxt prepare`, `nuxi`, or any other project build/development scripts.
- DO NOT attempt to compile, bundle, or verify code changes locally using terminal commands.
- You are ONLY permitted to use git commands (`git diff`, `git log`, `git status`, `git show`), file reading/search tools (`grep`, `cat`, ripgrep, file view), and `docker compose exec db ...` for read-only PostgreSQL inspection.
- Do NOT use `git merge-base`. Inspect changes directly using `git diff <base>...HEAD`, `git log`, or `git show`.
- Database inspection commands must use read-only SQL. Do not insert, update, delete, truncate, alter, drop, migrate, or seed data unless the user explicitly requests it.

## Review Workflow

### 1. Identify & Inspect Changes
- Inspect the git diff for the branch or specified commits (e.g. `git diff master...HEAD`, `git diff HEAD~1`, or unstaged/staged working changes).
- Identify all modified, added, or deleted files.
- Understand the scope of changes without requiring a User Manual (UM), requirement document, or task ticket.

### 2. Impact & Flow Analysis (Breaking Changes & Side Effects)
Analyze how the changes interact with the rest of the codebase:
- **Call-Site & Usages**: For every modified or removed function, component, composable, helper, or endpoint, search the entire codebase to verify all existing call sites remain compatible.
- **API Contracts**: Verify whether endpoint URL routes, request parameters/payloads, or response structures changed in ways that could break frontend callers or other services.
- **Database & Schema Changes**: Verify if schema changes or migrations affect existing queries, joined models, or data integrity across the app.
- **Dual-Monitor POS Workflow**: If changes affect POS screens (`/pos` or `/pos/customer`), ensure `BroadcastChannel` synchronization, state sharing, and layout separation between staff and customer displays are preserved.
- **Receipt Layout Sync**: If changes touch `web/app/components/pos/shared/CartSummary.vue` or `web/server/api/sales/_print_receipt.ts`, check if the other needs a matching layout/formatting update to stay in sync.
- **Stale Base for Shared Artifacts**: If a shared utility, helper, database migration, or service method was rewritten, ensure existing functionality and prior bug fixes were not accidentally dropped or reverted.

### 3. Prasenz-Core Engineering Standards & Conventions
Check that the code strictly adheres to project conventions:

#### Backend & Database (Nitro / Drizzle)
- **Soft Deletes**: Tables with an `active` column must NEVER have hard deletes (`DELETE FROM ...`). Use soft deletes (`active = false`).
- **Active Query Filtering**: All database queries MUST include `active = true` for every table that has an `active` column by default (including joined tables and aggregates).
- **No Foreign Keys**: Ensure Drizzle schemas and SQL migrations do NOT use foreign key constraints (`.references()`). Manage relations via joins.
- **Naming**: Plural nouns in `snake_case` for tables, singular `snake_case` for columns and schema properties, `{referenced_table_singular}_id` for relations.
- **Data Types**: Use `text()` for strings (no `varchar`), `timestamp(..., { withTimezone: true })` for dates.
- **Timestamps**: Ensure `created_at` and `updated_at` (timestamptz) use `.defaultNow()`.
- **API Routing & Handlers**: Table-based routes using `[...].ts` with `createRouter()` and `useBase()`. Use `apiHandler(schemas, handler)` from `#server/utils/api` with Zod schemas in `_schema.ts`.
- **Service Layer**: Non-trivial business logic must reside in a `_service.ts` class, not inline within route handlers.
- **Server Imports**: Internal server imports must use the `#server` alias (e.g. `#server/db/database`).
- **API Responses**: Return plain objects/arrays without wrapping in `{ data: ... }`. Joined relation data must be nested in named objects (e.g. `serving_type: { id, code, name }`), not flattened to top-level.
- **Error Handling**: Use `createError({ statusCode, statusMessage })` for HTTP errors.

#### Frontend (Nuxt 4 / Vue 3 / Vuetify)
- **Vue Block Order**: Strictly `<template>`, then `<script setup>`, then `<style lang="scss">`.
- **Frontend Language**: Plain JavaScript in `<script setup>` (no `lang="ts"` unless explicitly requested).
- **API Requests**: Destructure API client via `const { $api } = useNuxtApp()`. Never chain directly off `useNuxtApp()`.
- **UI Components**: Prefer Vuetify components with `v-` prefix (`<v-btn />`, `<v-text-field />`, `<v-dialog />`, etc.).
- **Table Loading**: Use `v-progress-circular` with `color="primary"`; never text like "Đang tải".
- **Styling**: Scoped SCSS (`<style lang="scss" scoped>`) using CSS nesting, surface variables (`--surface-*`), and POS design tokens (`--pos-*`).
- **Custom Icons**: Use `<nuxt-icon name="..." filled />`, never raw `<svg>` tags.

#### General
- **Date/Time Handling**: Must use `moment` forced to UTC+07:00 (Vietnam Time), e.g. `moment().utcOffset(7 * 60)`. Flag any native `new Date()` or `Date.now()` without UTC+07 handling.
- **Lodash**: Prefer `lodash` utilities (`_.get`, `_.set`, `_.cloneDeep`, etc.) for robust data transformations.
- **Code Comments**: MUST be written in English. Vietnamese is reserved only for user-facing UI text, error status messages, toast notifications, or seed data.
- **DRY & Code Reuse**: Identify duplicated code or re-implemented logic that should reuse existing helpers, composables, or service methods.

### 4. Bugs, Edge Cases & Performance
- **Edge Cases**: Missing null/undefined checks, empty arrays/objects, boundary conditions, unhandled falsy values.
- **Error Handling**: Uncaught promises, missing try/catch around external calls, unhandled edge responses.
- **Performance**: N+1 database queries, unnecessary re-renders, missing database indexes on queried columns, memory leaks, unclosed listeners/channels.

### 5. Review Report
Produce a structured review report using [Report Format](./references/report_format.md).
