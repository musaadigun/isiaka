# Isiaka

A modern, minimal React application scaffold built with [Vite](https://vite.dev).
Routing, testing, and linting come preconfigured so you can start building
features immediately.

## Tech stack

| Tool                                                     | Purpose                        |
| -------------------------------------------------------- | ------------------------------ |
| [React 19](https://react.dev)                            | UI library                     |
| [Vite](https://vite.dev)                                 | Build tool & dev server        |
| [React Router](https://reactrouter.com)                  | Client-side routing            |
| [Vitest](https://vitest.dev)                             | Test runner                    |
| [Testing Library](https://testing-library.com)           | Component testing utilities    |
| [ESLint](https://eslint.org)                             | Linting (flat config)          |

## Getting started

Requires **Node.js 18+**.

```bash
# Install dependencies
npm install

# Start the dev server (http://localhost:5173)
npm run dev
```

## Available scripts

| Command              | Description                                        |
| -------------------- | -------------------------------------------------- |
| `npm run dev`        | Start the Vite dev server with hot module reload.  |
| `npm run build`      | Produce an optimized production build in `dist/`.  |
| `npm run preview`    | Preview the production build locally.              |
| `npm run lint`       | Lint all source files with ESLint.                 |
| `npm test`           | Run the test suite once.                           |
| `npm run test:watch` | Run tests in interactive watch mode.               |

## Project structure

```
isiaka/
├── public/                 # Static assets served as-is
│   └── favicon.svg
├── src/
│   ├── components/         # Reusable UI components (+ CSS modules)
│   │   ├── Counter.jsx
│   │   ├── Footer.jsx
│   │   └── Navbar.jsx
│   ├── hooks/              # Custom React hooks
│   │   └── useDocumentTitle.js
│   ├── layouts/            # Shared page shells
│   │   └── RootLayout.jsx
│   ├── pages/              # Route-level components
│   │   ├── Home.jsx
│   │   ├── About.jsx
│   │   └── NotFound.jsx
│   ├── test/               # Test setup + specs
│   │   ├── setup.js
│   │   ├── App.test.jsx
│   │   └── Counter.test.jsx
│   ├── App.jsx             # Route table
│   ├── main.jsx            # App entry point
│   └── index.css           # Global styles & design tokens
├── eslint.config.js
├── vite.config.js
└── index.html
```

## Adding a page

1. Create a component in `src/pages/`, e.g. `Contact.jsx`.
2. Register it in `src/App.jsx`:

   ```jsx
   import Contact from './pages/Contact.jsx'

   // inside <Route element={<RootLayout />}> …
   <Route path="contact" element={<Contact />} />
   ```

3. Add a link in `src/components/Navbar.jsx` if it belongs in the nav.

## Styling

Global design tokens (colors, spacing, radii) live in `src/index.css` as CSS
custom properties and include a light/dark theme via `prefers-color-scheme`.
Component-scoped styles use [CSS Modules](https://vite.dev/guide/features#css-modules)
(`*.module.css`).
