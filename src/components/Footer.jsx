import styles from './Footer.module.css'

function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={`container ${styles.inner}`}>
        <span>© {new Date().getFullYear()} Isiaka</span>
        <a
          href="https://react.dev"
          target="_blank"
          rel="noreferrer"
          className={styles.link}
        >
          Built with React &amp; Vite
        </a>
      </div>
    </footer>
  )
}

export default Footer
