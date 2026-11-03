// The hero carousel. A pink bar fills under the current device; when it finishes, the next device
// fades in. Choosing a device stops the rotation for good. Reduced Motion never starts it.
const show = document.querySelector("[data-show]");
const slides = [...show.querySelectorAll(".slide")];
const notes = [...show.querySelectorAll(".notes p")];
const buttons = [...show.querySelectorAll(".picker button")];
let current = 0;

function go(index) {
	current = index;
	slides.forEach((slide, i) => slide.classList.toggle("on", i === index));
	notes.forEach((note, i) => note.classList.toggle("on", i === index));
	buttons.forEach((button, i) => (i === index ? button.setAttribute("aria-current", "true") : button.removeAttribute("aria-current")));
}

buttons.forEach((button, i) => {
	button.addEventListener("click", () => {
		show.classList.remove("running");
		go(i);
	});
});
show.addEventListener("animationend", () => go((current + 1) % slides.length));

for (const [on, off] of [["pointerenter", "pointerleave"], ["focusin", "focusout"]]) {
	show.addEventListener(on, () => show.classList.add("paused"));
	show.addEventListener(off, () => show.classList.remove("paused"));
}

if (!matchMedia("(prefers-reduced-motion: reduce)").matches) show.classList.add("running");
