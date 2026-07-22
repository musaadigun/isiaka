import { NavLink } from 'react-router-dom'
import styles from './Navbar.module.css'

const links = [
  { to: '/', label: 'Home', end: true },
  { to: '/about', label: 'About' },
]

function Navbar() {
  return (
    <header className={styles.header}>
      <nav className={`container ${styles.nav}`}>
        <NavLink to="/" className={styles.brand} end>
          <span className={styles.logo} aria-hidden="true">◆</span>
          Isiaka
        </NavLink>
        <ul className={styles.links}>
          {links.map(({ to, label, end }) => (
            <li key={to}>
              <NavLink
                to={to}
                end={end}
                className={({ isActive }) =>
                  isActive ? `${styles.link} ${styles.active}` : styles.link
                }
              >
                {label}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
    </header>
  )
}

export default Navbar
