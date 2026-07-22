import { useDocumentTitle } from '../hooks/useDocumentTitle.js'
import Counter from '../components/Counter.jsx'

const stack = [
  ['React', 'UI library (v19)'],
  ['Vite', 'Build tool & dev server'],
  ['React Router', 'Client-side routing'],
  ['Vitest', 'Test runner'],
  ['Testing Library', 'Component testing utilities'],
  ['ESLint', 'Linting (flat config)'],
]

function About() {
  useDocumentTitle('About')

  return (
    <div>
      <h1>About this scaffold</h1>
      <p style={{ color: 'var(--color-text-muted)', maxWidth: '60ch' }}>
        This project is a lightweight starting point for building React
        applications. It wires up routing, testing, and linting with sensible
        defaults so you can focus on your product instead of configuration.
      </p>

      <h2 style={{ marginTop: 'var(--space-5)' }}>Tech stack</h2>
      <ul style={{ maxWidth: '60ch', paddingLeft: '1.25rem' }}>
        {stack.map(([name, description]) => (
          <li key={name} style={{ marginBottom: 'var(--space-1)' }}>
            <strong>{name}</strong> — {description}
          </li>
        ))}
      </ul>

      <h2 style={{ marginTop: 'var(--space-5)' }}>Interactive example</h2>
      <p style={{ color: 'var(--color-text-muted)' }}>
        A small stateful component to confirm everything is running:
      </p>
      <Counter />
    </div>
  )
}

export default About
