import { useState } from 'react'
import styles from './Counter.module.css'

/**
 * Minimal stateful example component demonstrating `useState`.
 */
function Counter({ initial = 0, step = 1 }) {
  const [count, setCount] = useState(initial)

  return (
    <div className={styles.counter}>
      <button
        type="button"
        className={styles.button}
        onClick={() => setCount((c) => c - step)}
        aria-label="Decrement"
      >
        −
      </button>
      <output className={styles.value} aria-live="polite">
        {count}
      </output>
      <button
        type="button"
        className={styles.button}
        onClick={() => setCount((c) => c + step)}
        aria-label="Increment"
      >
        +
      </button>
      <button
        type="button"
        className={styles.reset}
        onClick={() => setCount(initial)}
      >
        Reset
      </button>
    </div>
  )
}

export default Counter
