/* The Ink / Paper switch. The inline script in <head> has already set data-theme before the
   first paint; this only shows the button and remembers the reader's choice. Without script the
   page follows the system's preference and the button stays hidden. */
(function () {
  var root = document.documentElement;
  var button = document.getElementById("mode");
  var name = document.getElementById("modeName");
  if (!button || !name) return;
  function show() {
    var t = root.getAttribute("data-theme") === "paper" ? "paper" : "ink";
    name.textContent = t;
    button.setAttribute("aria-label", "Reading in " + t + ". Switch to " + (t === "paper" ? "ink" : "paper") + ".");
  }
  button.addEventListener("click", function () {
    var next = root.getAttribute("data-theme") === "paper" ? "ink" : "paper";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("noeticecho.theme", next); } catch (e) {}
    show();
  });
  button.hidden = false;
  show();
})();
