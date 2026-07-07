import js from '@eslint/js';
import tseslint from 'typescript-eslint';

// ESLint 9 flat config. Deliberately the NON-type-checked typescript-eslint preset:
// `npm run lint` stays fast (no tsc program build) — `npm run typecheck` owns the
// type-level checks.
export default tseslint.config(
  { ignores: ['dist/', 'node_modules/', '.dab-attachments/'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.ts'],
    rules: {
      // Intentionally-unused values are underscore-prefixed throughout the codebase
      // (e.g. `_ctx`, destructuring rests); flag only the non-prefixed ones.
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' },
      ],
    },
  },
);
