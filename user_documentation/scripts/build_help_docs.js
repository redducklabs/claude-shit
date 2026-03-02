/**
 * Build script for in-app help documentation.
 *
 * Reads markdown files from a docs directory, parses YAML frontmatter,
 * processes section visibility markers, converts to HTML, rewrites image/link
 * paths, and outputs a JSON manifest for the frontend.
 *
 * Configuration is read from help-docs.config.json (co-located with this
 * script) or via environment variables. See the config file for defaults.
 *
 * Run: node scripts/build_help_docs.js
 *
 * Dependencies: gray-matter, marked
 *   npm install gray-matter marked
 */

const fs = require("fs");
const path = require("path");
const matter = require("gray-matter");
const { marked } = require("marked");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const CONFIG_PATH = path.resolve(__dirname, "help-docs.config.json");

let fileConfig = {};
if (fs.existsSync(CONFIG_PATH)) {
  fileConfig = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
}

const DOCS_DIR =
  process.env.HELP_DOCS_DIR ||
  path.resolve(__dirname, fileConfig.docsDir || "../../docs/user_documentation");

const OUTPUT_JSON =
  process.env.HELP_OUTPUT_JSON ||
  path.resolve(__dirname, fileConfig.outputJson || "../src/generated/help-docs.json");

const OUTPUT_IMAGES_DIR =
  process.env.HELP_OUTPUT_IMAGES_DIR ||
  path.resolve(
    __dirname,
    fileConfig.outputImagesDir || "../public/help-images"
  );

const HELP_ROUTE_PREFIX =
  process.env.HELP_ROUTE_PREFIX || fileConfig.helpRoutePrefix || "/help";

// Category ordering — read from config file
const CATEGORY_ORDER = fileConfig.categories || {};

// Section visibility markers
const SECTION_OPEN_RE = /^<!--\s*help:(provider|admin|member)\s*-->$/;
const SECTION_CLOSE_RE = /^<!--\s*\/help:(provider|admin|member)\s*-->$/;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function filenameToSlug(filename) {
  return path.basename(filename, path.extname(filename));
}

function filenameToTitle(filename) {
  const stem = path.basename(filename, path.extname(filename));
  return stem
    .replace(/-/g, " ")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

/**
 * Process section visibility markers in markdown.
 *
 * Converts:
 *   <!-- help:admin -->
 *   ## Section
 *   Content...
 *   <!-- /help:admin -->
 *
 * Into:
 *   <div class="help-section" data-visibility="admin">
 *
 *   ## Section
 *   Content...
 *
 *   </div>
 */
function processVisibilityMarkers(markdownBody) {
  const lines = markdownBody.split("\n");
  const result = [];

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();

    const openMatch = trimmed.match(SECTION_OPEN_RE);
    if (openMatch) {
      const tier = openMatch[1];
      result.push(
        `<div class="help-section" data-visibility="${tier}">\n`
      );
      continue;
    }

    const closeMatch = trimmed.match(SECTION_CLOSE_RE);
    if (closeMatch) {
      result.push(`\n</div>`);
      continue;
    }

    result.push(lines[i]);
  }

  return result.join("\n");
}

/**
 * Rewrite image paths from relative markdown paths to {helpRoutePrefix}-images/{category}/
 */
function rewriteImagePaths(html, categorySlug) {
  const imagesPrefix = `${HELP_ROUTE_PREFIX}-images`.replace(/^\//, "/");
  return html.replace(
    /src="(?:\.\/)?images\/([^"]+)"/g,
    `src="${imagesPrefix}/${categorySlug}/$1"`
  );
}

/**
 * Rewrite inter-doc links to in-app routes.
 *
 * Converts href="../calendar/master-calendar.md"
 *      to href="{HELP_ROUTE_PREFIX}/calendar/master-calendar"
 */
function rewriteDocLinks(html, currentCategorySlug) {
  return html.replace(/href="([^"]*\.md)"/g, (match, href) => {
    const parts = href.replace(/\\/g, "/").split("/");
    const filename = parts[parts.length - 1];
    const pageSlug = filename.replace(/\.md$/, "");

    let category = currentCategorySlug;
    for (let i = 0; i < parts.length - 1; i++) {
      const part = parts[i];
      if (part !== "." && part !== "..") {
        category = part;
      }
    }

    return `href="${HELP_ROUTE_PREFIX}/${category}/${pageSlug}"`;
  });
}

/**
 * Copy images from a category's images/ dir to the output images directory.
 */
function copyImages(categoryDir, categorySlug) {
  const imagesDir = path.join(categoryDir, "images");
  if (!fs.existsSync(imagesDir)) return;

  const destDir = path.join(OUTPUT_IMAGES_DIR, categorySlug);
  fs.mkdirSync(destDir, { recursive: true });

  const files = fs.readdirSync(imagesDir);
  for (const file of files) {
    const src = path.join(imagesDir, file);
    const dest = path.join(destDir, file);
    if (fs.statSync(src).isFile()) {
      fs.copyFileSync(src, dest);
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function build() {
  console.log(`[build-help-docs] Reading docs from: ${DOCS_DIR}`);
  console.log(`[build-help-docs] Help route prefix: ${HELP_ROUTE_PREFIX}`);

  if (!fs.existsSync(DOCS_DIR)) {
    console.warn(
      `[build-help-docs] Docs directory not found: ${DOCS_DIR}. Generating empty manifest.`
    );
    const outputDir = path.dirname(OUTPUT_JSON);
    fs.mkdirSync(outputDir, { recursive: true });
    fs.writeFileSync(OUTPUT_JSON, JSON.stringify({ categories: [] }, null, 2));
    return;
  }

  if (Object.keys(CATEGORY_ORDER).length === 0) {
    console.warn(
      "[build-help-docs] No categories defined in config. " +
        "Add entries to 'categories' in help-docs.config.json."
    );
  }

  marked.setOptions({
    gfm: true,
    breaks: false,
  });

  const categories = [];

  // Clean output image dir
  let canWriteImages = true;
  if (fs.existsSync(OUTPUT_IMAGES_DIR)) {
    try {
      fs.rmSync(OUTPUT_IMAGES_DIR, { recursive: true });
    } catch (err) {
      if (err.code === "EROFS" || err.code === "EACCES") {
        console.warn(
          "[build-help-docs] Read-only filesystem, skipping image copy"
        );
        canWriteImages = false;
      } else {
        throw err;
      }
    }
  }

  // Read subdirectories
  const entries = fs.readdirSync(DOCS_DIR, { withFileTypes: true });
  const subdirs = entries.filter((e) => e.isDirectory() && e.name !== "images");

  for (const subdir of subdirs) {
    const dirName = subdir.name;
    const dirPath = path.join(DOCS_DIR, dirName);
    const categoryConfig = CATEGORY_ORDER[dirName];

    if (!categoryConfig) {
      console.warn(
        `[build-help-docs] Unknown category directory: ${dirName}, skipping`
      );
      continue;
    }

    const mdFiles = fs
      .readdirSync(dirPath)
      .filter(
        (f) => f.endsWith(".md") && f.toLowerCase() !== "readme.md"
      )
      .sort();

    const pages = [];

    for (const mdFile of mdFiles) {
      const filePath = path.join(dirPath, mdFile);
      const raw = fs.readFileSync(filePath, "utf-8");

      const { data: frontmatter, content: markdownBody } = matter(raw);

      const title = frontmatter.title || filenameToTitle(mdFile);
      const visibility = frontmatter.visibility || "all";
      const pageOrder =
        typeof frontmatter.order === "number" ? frontmatter.order : 99;
      const slug = filenameToSlug(mdFile);

      const processedMarkdown = processVisibilityMarkers(markdownBody);
      let html = marked.parse(processedMarkdown);
      html = rewriteImagePaths(html, dirName);
      html = rewriteDocLinks(html, dirName);

      pages.push({
        slug,
        title,
        visibility,
        order: pageOrder,
        html,
        category: dirName,
      });
    }

    pages.sort((a, b) => a.order - b.order);

    if (canWriteImages) {
      copyImages(dirPath, dirName);
    }

    categories.push({
      slug: dirName,
      title: categoryConfig.title,
      order: categoryConfig.order,
      pages,
    });
  }

  categories.sort((a, b) => a.order - b.order);

  // Write JSON manifest
  const manifest = { categories };
  try {
    const outputDir = path.dirname(OUTPUT_JSON);
    fs.mkdirSync(outputDir, { recursive: true });
    fs.writeFileSync(OUTPUT_JSON, JSON.stringify(manifest, null, 2));
  } catch (err) {
    if (err.code === "EROFS" || err.code === "EACCES") {
      console.warn("[build-help-docs] Read-only filesystem, skipping JSON write");
      return;
    }
    throw err;
  }

  const totalPages = categories.reduce((sum, c) => sum + c.pages.length, 0);
  console.log(
    `[build-help-docs] Generated ${categories.length} categories, ${totalPages} pages`
  );
  console.log(`[build-help-docs] Output: ${OUTPUT_JSON}`);
}

build();
