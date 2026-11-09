/* TR Design System theme and mode for the whole site — the only place that names
   the theme. Loaded synchronously in <head>, before the stylesheets, so the first
   paint already has the right tokens. The mode follows the system appearance and
   Increase Contrast; elements with data-tr-lock="dark" (the app mockup) stay dark,
   like the app's viewfinder. */
(function () {
  var THEME = 'luminousStudio';
  var d = document.documentElement, dark = matchMedia('(prefers-color-scheme: dark)'), more = matchMedia('(prefers-contrast: more)');
  function apply() {
    var hc = more.matches ? 'HighContrast' : '';
    d.setAttribute('data-tr-theme', THEME);
    d.setAttribute('data-tr-mode', (dark.matches ? 'dark' : 'light') + hc);
    document.querySelectorAll('[data-tr-lock="dark"]').forEach(function (el) {
      el.setAttribute('data-tr-theme', THEME);
      el.setAttribute('data-tr-mode', 'dark' + hc);
    });
  }
  window.trApplyMode = apply;
  apply();
  dark.addEventListener('change', apply);
  more.addEventListener('change', apply);
  document.addEventListener('DOMContentLoaded', apply);
})();
