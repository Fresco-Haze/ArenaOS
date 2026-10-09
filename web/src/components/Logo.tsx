export default function Logo() {
  return (
    <span className="logo">
      <svg className="logo-glyph" viewBox="-8 0 80 66" aria-hidden="true">
        <defs>
          <mask id="logo-gap" maskUnits="userSpaceOnUse" x="-10" y="0" width="84" height="70">
            <rect x="-10" y="0" width="84" height="70" fill="#fff" />
            <path d="M-6 50L68 20L30 41ZM-2 64L52 40L24 58Z" fill="#000" stroke="#000" strokeWidth="8" strokeLinejoin="round" />
          </mask>
        </defs>
        <path className="logo-a-shape" mask="url(#logo-gap)" d="M2 60L24 4H40L62 60H47L32 21L17 60Z" />
        <path className="logo-blade-1" d="M-6 50L68 20L30 41Z" />
        <path className="logo-blade-2" d="M-2 64L52 40L24 58Z" />
      </svg>
      <span className="logo-text">rena<span className="logo-os">OS</span></span>
    </span>
  )
}