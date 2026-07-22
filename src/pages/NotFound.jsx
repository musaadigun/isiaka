import { Link } from 'react-router-dom'
import { useDocumentTitle } from '../hooks/useDocumentTitle.js'

function NotFound() {
  useDocumentTitle('Page not found')

  return (
    <div style={{ textAlign: 'center', paddingBlock: 'var(--space-6)' }}>
      <p
        style={{
          fontSize: '4rem',
          fontWeight: 800,
          color: 'var(--color-primary)',
          margin: 0,
        }}
      >
        404
      </p>
      <h1>Page not found</h1>
      <p style={{ color: 'var(--color-text-muted)' }}>
        The page you&rsquo;re looking for doesn&rsquo;t exist or has moved.
      </p>
      <Link to="/">← Back home</Link>
    </div>
  )
}

export default NotFound
