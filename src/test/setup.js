// Vitest setup: runs before each test file.
// Adds custom jest-dom matchers (e.g. toBeInTheDocument) and cleans up
// the DOM after every test.
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'

afterEach(() => {
  cleanup()
})
