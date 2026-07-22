import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import Counter from '../components/Counter.jsx'

describe('Counter', () => {
  it('renders the initial value', () => {
    render(<Counter initial={5} />)
    expect(screen.getByRole('status')).toHaveTextContent('5')
  })

  it('increments and decrements', async () => {
    const user = userEvent.setup()
    render(<Counter />)

    await user.click(screen.getByRole('button', { name: /increment/i }))
    await user.click(screen.getByRole('button', { name: /increment/i }))
    expect(screen.getByRole('status')).toHaveTextContent('2')

    await user.click(screen.getByRole('button', { name: /decrement/i }))
    expect(screen.getByRole('status')).toHaveTextContent('1')
  })

  it('resets to the initial value', async () => {
    const user = userEvent.setup()
    render(<Counter initial={3} />)

    await user.click(screen.getByRole('button', { name: /increment/i }))
    await user.click(screen.getByRole('button', { name: /reset/i }))
    expect(screen.getByRole('status')).toHaveTextContent('3')
  })
})
