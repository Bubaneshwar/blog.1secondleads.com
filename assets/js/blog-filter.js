(function () {
  // Single-select category filter for the /blog/ directory. Clicking a sidebar
  // chip shows only the posts in that category and swaps the content header to
  // the matching category title + description. "All Posts" clears the filter.
  function normalize(value) {
    return (value || '').toString().trim().toLowerCase();
  }

  function getActive() {
    var input = document.getElementById('blog-category-filter');
    return input ? normalize(input.value) : '';
  }

  function setHidden(element, hidden) {
    if (!element) return;
    element.classList.toggle('d-none', hidden);
  }

  function cardCategories(card) {
    return normalize(card.getAttribute('data-blog-cats')).split('|').filter(Boolean);
  }

  function apply() {
    var active = getActive();
    var cards = document.querySelectorAll('#blog-post-list .blog-post-item');
    var visible = 0;

    Array.prototype.forEach.call(cards, function (card) {
      var match = active === '' || cardCategories(card).indexOf(active) !== -1;
      setHidden(card, !match);
      if (match) visible += 1;
    });

    // Swap the content-area header (title + description) to the active category.
    Array.prototype.forEach.call(document.querySelectorAll('[data-blog-head]'), function (head) {
      setHidden(head, normalize(head.getAttribute('data-blog-head')) !== active);
    });

    // Reflect the active state on the chips.
    Array.prototype.forEach.call(document.querySelectorAll('[data-blog-toggle]'), function (button) {
      button.classList.toggle('is-active', normalize(button.getAttribute('data-blog-toggle')) === active && active !== '');
    });
    Array.prototype.forEach.call(document.querySelectorAll('[data-blog-toggle-clear]'), function (button) {
      button.classList.toggle('is-active', active === '');
    });

    setHidden(document.getElementById('blog-empty'), visible !== 0);
  }

  function setCategory(value) {
    var input = document.getElementById('blog-category-filter');
    if (input) input.value = value || '';
    apply();
  }

  function bindAll(selector, handler) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), function (element) {
      element.addEventListener('click', handler);
    });
  }

  function init() {
    if (!document.getElementById('blog-category-filter')) return;
    bindAll('[data-blog-toggle]', function () {
      setCategory(this.getAttribute('data-blog-toggle'));
    });
    bindAll('[data-blog-toggle-clear]', function () {
      setCategory('');
    });
    apply();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
