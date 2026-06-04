(function () {
  function normalize(value) {
    return (value || '').toString().trim().toLowerCase();
  }

  function getValue(id) {
    var element = document.getElementById(id);
    return element ? normalize(element.value) : '';
  }

  function getData(element, key) {
    return normalize(element.getAttribute('data-' + key));
  }

  function getFilters(group) {
    var prefix = group === 'featured' ? 'featured' : 'all';

    return {
      category: getValue(prefix + '-category-filter'),
      pricing: getValue(prefix + '-pricing-filter')
    };
  }

  function cardMatches(card, filters) {
    var categories = getData(card, 'category').split('|');
    var pricing = getData(card, 'pricing');
    var selectedCategories = filters.category ? filters.category.split('|') : [];

    if (selectedCategories.length > 0 && !selectedCategories.some(function (category) { return categories.indexOf(category) !== -1; })) {
      return false;
    }

    if (filters.pricing && pricing !== filters.pricing) {
      return false;
    }

    return true;
  }

  function setHidden(element, hidden) {
    if (hidden) {
      element.classList.add('d-none');
    } else {
      element.classList.remove('d-none');
    }
  }

  function filterCards(group, selector, emptyId) {
    var filters = getFilters(group);
    var cards = document.querySelectorAll(selector);
    var visible = 0;

    Array.prototype.forEach.call(cards, function (card) {
      var isVisible = cardMatches(card, filters);
      setHidden(card, !isVisible);

      if (isVisible) {
        visible += 1;
      }
    });

    var empty = document.getElementById(emptyId);
    if (empty) {
      setHidden(empty, visible !== 0);
    }
  }

  function updateCategoryGroups() {
    var category = getValue('all-category-filter');
    var selectedCategories = category ? category.split('|') : [];
    var visibleGroups = 0;

    Array.prototype.forEach.call(document.querySelectorAll('[data-category-group]'), function (group) {
      var groupCategory = group.getAttribute('data-category-group');
      var categoryMatch = selectedCategories.length === 0 || selectedCategories.indexOf(groupCategory) !== -1;
      // A group is only worth showing if it still has at least one visible card
      // after the search/pricing filters ran (filterCards toggled .d-none already).
      var hasVisibleItems = group.querySelectorAll('.tool-list-item:not(.d-none)').length > 0;
      var isVisible = categoryMatch && hasVisibleItems;
      setHidden(group, !isVisible);

      if (isVisible) {
        visibleGroups += 1;
      }
    });

    var placeholder = document.getElementById('tools-category-placeholder');
    if (placeholder) {
      setHidden(placeholder, visibleGroups !== 0);
    }
  }

  function applyFilters() {
    filterCards('featured', '#featured-tools .tool-card', 'featured-tools-empty');
    filterCards('all', '#all-tools .tool-list-item', 'all-tools-empty');
    updateCategoryGroups();
    updateAllToolsActiveCategory();
    updateFeaturedActiveCategory();
    updateClearButtons();
  }

  function updateAllToolsActiveCategory() {
    var category = getValue('all-category-filter');
    var selectedCategories = category ? category.split('|') : [];
    var allTools = document.getElementById('all-tools');

    if (allTools) {
      allTools.classList.toggle('tools-list--filtered', selectedCategories.length > 0);
    }

    Array.prototype.forEach.call(document.querySelectorAll('[data-category-toggle]'), function (button) {
      button.classList.toggle('is-active', selectedCategories.indexOf(button.getAttribute('data-category-toggle')) !== -1);
    });

    Array.prototype.forEach.call(document.querySelectorAll('[data-category-toggle-clear]'), function (button) {
      button.classList.toggle('is-active', selectedCategories.length === 0);
    });
  }

  function updateFeaturedActiveCategory() {
    var category = getValue('featured-category-filter');

    Array.prototype.forEach.call(document.querySelectorAll('[data-featured-category-toggle]'), function (button) {
      button.classList.toggle('is-active', button.getAttribute('data-featured-category-toggle') === category);
    });
  }

  function updateClearButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-clear-group]'), function (button) {
      var group = button.getAttribute('data-clear-group');
      var hasCategory = Boolean(getFilters(group).category);
      setHidden(button, !hasCategory);
    });
  }

  // Keyword stopwords so a natural query like "tools for cold outreach" matches on
  // the meaningful terms ("cold", "outreach") instead of failing on the filler words.
  var SEARCH_STOPWORDS = {
    a: true, an: true, and: true, app: true, apps: true, best: true, find: true,
    'for': true, 'in': true, me: true, my: true, of: true, platform: true,
    platforms: true, search: true, show: true, software: true, solution: true,
    solutions: true, the: true, to: true, tool: true, tools: true, top: true,
    'with': true
  };

  var toolIndex = null;

  function getToolIndex() {
    if (toolIndex) {
      return toolIndex;
    }
    var node = document.getElementById('tools-search-data');
    if (!node) {
      toolIndex = [];
      return toolIndex;
    }
    try {
      toolIndex = JSON.parse(node.textContent) || [];
    } catch (error) {
      toolIndex = [];
    }
    return toolIndex;
  }

  function queryTokens(query) {
    return normalize(query).split(/[^a-z0-9]+/).filter(function (token) {
      return token.length > 1 && !SEARCH_STOPWORDS[token];
    });
  }

  function searchTools(query) {
    var tokens = queryTokens(query);
    if (tokens.length === 0) {
      return [];
    }

    var matches = [];
    Array.prototype.forEach.call(getToolIndex(), function (tool) {
      var haystack = tool.search || '';
      var matched = 0;
      tokens.forEach(function (token) {
        if (haystack.indexOf(token) !== -1) {
          matched += 1;
        }
      });
      // Require every meaningful token to appear, so results stay relevant.
      if (matched === tokens.length) {
        var name = normalize(tool.name);
        // Rank by token hits, then favour a name that starts with the first token.
        var score = matched + (name.indexOf(tokens[0]) === 0 ? 2 : 0);
        matches.push({ tool: tool, score: score });
      }
    });

    matches.sort(function (a, b) { return b.score - a.score; });
    return matches.slice(0, 8).map(function (match) { return match.tool; });
  }

  function escapeHtml(value) {
    return (value == null ? '' : String(value))
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function renderSearchResult(tool) {
    var external = /^https?:/i.test(tool.url || '');
    var target = external ? ' target="_blank" rel="noopener noreferrer"' : '';
    var logo = tool.logo
      ? '<span class="tools-search-result__logo tools-search-result__logo--image" style="background-image: url(\'' + escapeHtml(tool.logo) + '\')" aria-hidden="true"></span>'
      : '<span class="tools-search-result__logo" aria-hidden="true">' + escapeHtml((tool.name || ' ').charAt(0).toUpperCase()) + '</span>';
    return '<a class="tools-search-result" href="' + escapeHtml(tool.url) + '"' + target + ' role="option">' +
      logo +
      '<span class="tools-search-result__text">' +
        '<span class="tools-search-result__name">' + escapeHtml(tool.name) + '</span>' +
        (tool.meta ? '<span class="tools-search-result__meta">' + escapeHtml(tool.meta) + '</span>' : '') +
      '</span>' +
      '<i data-lucide="chevron-right" class="tools-search-result__go" aria-hidden="true"></i>' +
      '</a>';
  }

  function updateSearchDropdown() {
    var search = document.getElementById('tools-search-input');
    var dropdown = document.getElementById('tools-search-dropdown');

    if (!search || !dropdown) {
      return;
    }

    var query = normalize(search.value);
    if (query.length < 2) {
      closeSearchDropdown();
      return;
    }

    var results = searchTools(query);
    if (results.length === 0) {
      dropdown.innerHTML = '<div class="tools-search-result tools-search-result--empty">No tools match &ldquo;' +
        escapeHtml(search.value.trim()) + '&rdquo;.</div>';
    } else {
      dropdown.innerHTML = results.map(renderSearchResult).join('');
      // The chevron icons are injected after lucide's initial page scan, so
      // ask lucide to replace the freshly-rendered <i data-lucide> elements.
      if (window.lucide && typeof window.lucide.createIcons === 'function') {
        window.lucide.createIcons();
      }
    }

    dropdown.classList.remove('d-none');
    search.setAttribute('aria-expanded', 'true');
  }

  function closeSearchDropdown() {
    var search = document.getElementById('tools-search-input');
    var dropdown = document.getElementById('tools-search-dropdown');

    if (dropdown) {
      dropdown.classList.add('d-none');
    }

    if (search) {
      search.setAttribute('aria-expanded', 'false');
    }
  }

  function bindAll(selector, eventName, callback) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), function (element) {
      element.addEventListener(eventName, callback);
    });
  }

  function initSingleToolCategories() {
    bindAll('[data-single-tool-category-toggle]', 'click', function () {
      var button = this;
      var list = button.closest('.single-tool-category-list');
      var isExpanded = button.getAttribute('aria-expanded') === 'true';

      if (!list) {
        return;
      }

      Array.prototype.forEach.call(list.querySelectorAll('[data-single-tool-extra-category]'), function (category) {
        category.classList.toggle('d-none', isExpanded);
      });

      button.setAttribute('aria-expanded', isExpanded ? 'false' : 'true');
      button.textContent = isExpanded ? button.getAttribute('data-collapsed-label') : 'Show less';
    });

    Array.prototype.forEach.call(document.querySelectorAll('[data-single-tool-category-toggle]'), function (button) {
      button.setAttribute('data-collapsed-label', button.textContent.trim());
    });
  }

  function initToolsFilter() {
    initSingleToolCategories();

    var search = document.getElementById('tools-search-input');
    if (search) {
      search.addEventListener('input', updateSearchDropdown);
      search.addEventListener('search', updateSearchDropdown);
      search.addEventListener('focus', updateSearchDropdown);
      search.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          closeSearchDropdown();
        }
      });
    }

    bindAll('[data-filter-group]', 'change', applyFilters);

    bindAll('[data-featured-category-toggle]', 'click', function () {
      var featuredCategoryFilter = document.getElementById('featured-category-filter');
      var selectedCategory = this.getAttribute('data-featured-category-toggle');
      if (featuredCategoryFilter) {
        featuredCategoryFilter.value = selectedCategory;
      }
      applyFilters();
    });

    bindAll('[data-category-toggle]', 'click', function () {
      var allCategoryFilter = document.getElementById('all-category-filter');
      var selectedCategory = this.getAttribute('data-category-toggle');
      if (allCategoryFilter) {
        var selectedCategories = allCategoryFilter.value ? allCategoryFilter.value.split('|') : [];
        var categoryIndex = selectedCategories.indexOf(selectedCategory);

        if (categoryIndex === -1) {
          selectedCategories.push(selectedCategory);
        } else {
          selectedCategories.splice(categoryIndex, 1);
        }

        allCategoryFilter.value = selectedCategories.join('|');
      }
      applyFilters();
    });

    bindAll('[data-category-toggle-clear]', 'click', function () {
      var allCategoryFilter = document.getElementById('all-category-filter');
      if (allCategoryFilter) {
        allCategoryFilter.value = '';
      }
      applyFilters();
    });

    bindAll('[data-clear-group]', 'click', function () {
      var group = this.getAttribute('data-clear-group');
      Array.prototype.forEach.call(document.querySelectorAll('[data-filter-group="' + group + '"]'), function (control) {
        control.value = '';
      });
      applyFilters();
    });

    document.addEventListener('click', function (event) {
      var searchBox = document.querySelector('.tools-search__box');
      if (searchBox && !searchBox.contains(event.target)) {
        closeSearchDropdown();
      }
    });

    applyFilters();
  }

  function initToolsTopNav() {
    var nav = document.querySelector('.tools-top-nav');
    var hero = document.querySelector('.tools-hero') || document.querySelector('.single-tool-hero');

    if (!nav || !hero) {
      return;
    }

    function updateNavState() {
      var heroBottom = hero.getBoundingClientRect().bottom;
      nav.classList.toggle('tools-top-nav--transparent', heroBottom <= 0);
    }

    updateNavState();
    window.addEventListener('scroll', updateNavState, { passive: true });
    window.addEventListener('resize', updateNavState);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      initToolsFilter();
      initToolsTopNav();
    });
  } else {
    initToolsFilter();
    initToolsTopNav();
  }
})();
