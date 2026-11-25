# Agents

- Live writes must stay within the user's authorized test scope. Use explicit IDs, modify only disposable test data, and delete it afterward with verified cleanup. Never use the default calendar implicitly in a test.
- Prefer existing dependencies. Do not add permanent unit/integration tests unless requested.
