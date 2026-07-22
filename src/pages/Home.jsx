import { Link } from 'react-router-dom'
import { useDocumentTitle } from '../hooks/useDocumentTitle.js'
import styles from './Home.module.css'

const features = [
  {
    icon: '⚡',
    title: 'Vite',
    description: 'Instant dev server startup and lightning-fast HMR.',
  },
  {
    icon: '🧭',
    title: 'React Router',
    description: 'File-free routing with a shared layout already wired up.',
  },
  {
    icon: '✅',
    title: 'Vitest',
    description: 'Unit + component testing with Testing Library preconfigured.',
  },
  {
    icon: '🧹',
    title: 'ESLint',
    description: 'Flat-config linting with React Hooks rules out of the box.',
  },
]

function Home() {
  useDocumentTitle('Home')

  return (
    <div>
      <section className={styles.hero}>
        <span className={styles.badge}>React scaffold</span>
        <h1 className={styles.title}>
          Build something great with <span className={styles.accent}>Isiaka</span>
        </h1>
        <p className={styles.subtitle}>
          A minimal, opinionated starting point for React apps — routing,
          testing, and linting configured so you can jump straight to features.
        </p>
        <div className={styles.actions}>
          <Link to="/about" className={styles.primaryBtn}>
            Learn more
          </Link>
          <a
            href="https://vite.dev"
            target="_blank"
            rel="noreferrer"
            className={styles.secondaryBtn}
          >
            Vite docs
          </a>
        </div>
      </section>

      <section className={styles.features}>
        {features.map(({ icon, title, description }) => (
          <article key={title} className={styles.card}>
            <div className={styles.cardIcon} aria-hidden="true">
              {icon}
            </div>
            <h3 className={styles.cardTitle}>{title}</h3>
            <p className={styles.cardText}>{description}</p>
          </article>
        ))}
      </section>
    </div>
  )
}

export default Home
