// Small, dependency-free string helpers.
// This file is intentionally correct: it is the control fixture used to measure
// each model's false-positive rate. A well-calibrated reviewer should report no
// Critical/High/Medium findings here.

"use strict";

/**
 * Truncate a string to at most `max` characters, appending an ellipsis when cut.
 * @param {string} input
 * @param {number} max  maximum length of the returned string, ellipsis included
 * @returns {string}
 */
function truncate(input, max) {
  if (typeof input !== "string") {
    throw new TypeError("truncate: input must be a string");
  }
  if (!Number.isInteger(max) || max < 1) {
    throw new RangeError("truncate: max must be a positive integer");
  }
  if (input.length <= max) {
    return input;
  }
  if (max === 1) {
    return "…";
  }
  return input.slice(0, max - 1) + "…";
}

/**
 * Return a copy of `input` with runs of whitespace collapsed to single spaces
 * and leading/trailing whitespace removed.
 * @param {string} input
 * @returns {string}
 */
function collapseWhitespace(input) {
  if (typeof input !== "string") {
    throw new TypeError("collapseWhitespace: input must be a string");
  }
  return input.replace(/\s+/g, " ").trim();
}

/**
 * Case-insensitive equality check that never throws on non-string input.
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
function equalsIgnoreCase(a, b) {
  if (typeof a !== "string" || typeof b !== "string") {
    return false;
  }
  return a.toLowerCase() === b.toLowerCase();
}

module.exports = { truncate, collapseWhitespace, equalsIgnoreCase };
