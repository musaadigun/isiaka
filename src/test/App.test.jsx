import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import App from '../App.jsx'

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

describe('App routing', () => {
  it('renders the home page hero at "/"', () => {
    renderAt('/')
    expect(
      screen.getByRole('heading', { name: /build something great/i }),
    ).toBeInTheDocument()
  })

  it('renders the about page at "/about"', () => {
    renderAt('/about')
    expect(
      screen.getByRole('heading', { name: /about this scaffold/i }),
    ).toBeInTheDocument()
  })

  it('renders a 404 page for unknown routes', () => {
    renderAt('/does-not-exist')
    expect(
      screen.getByRole('heading', { name: /page not found/i }),
    ).toBeInTheDocument()
  })

  it('always shows the navbar brand', () => {
    renderAt('/')
    expect(screen.getAllByText(/isiaka/i).length).toBeGreaterThan(0)
  })
})
