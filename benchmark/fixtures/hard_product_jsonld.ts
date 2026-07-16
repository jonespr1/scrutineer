// Build Product + Breadcrumb JSON-LD for a catalogue product page.
//
// HARD fixture: realistic, mostly-correct structured-data builder with ONE buried defect. The
// suppliers list used to render outbound links (now removed) and is kept ONLY to resolve the
// brand name for JSON-LD. Finding the bug requires noticing what the filter gates on versus what
// is actually consumed downstream.

const SITE = "https://www.example-agri.co.uk";

interface Supplier {
  name: string;
  /** Optional outbound link. No longer rendered on the page. */
  url?: string;
}

interface Product {
  title: string;
  description: string;
  image: string;
  category: string;
  categoryLabel: string;
  suppliers: Supplier[];
}

/** Resolve the brand name for a product from its suppliers, falling back to the category. */
function brandName(product: Product): string {
  const suppliers = product.suppliers.filter((s) => /^https?:\/\//i.test(s.url ?? ""));
  if (suppliers.length > 0) {
    return suppliers[0].name;
  }
  return product.categoryLabel;
}

export function productJsonLd(product: Product, slug: string) {
  return {
    "@context": "https://schema.org",
    "@type": "Product",
    name: product.title,
    description: product.description,
    image: `${SITE}${product.image}`,
    url: `${SITE}/products/${slug}/`,
    category: product.categoryLabel,
    brand: { "@type": "Brand", name: brandName(product) },
  };
}

export function breadcrumbJsonLd(product: Product, slug: string) {
  const crumbs = [
    { name: "Home", item: `${SITE}/` },
    { name: product.categoryLabel, item: `${SITE}/categories/${product.category}/` },
    { name: product.title, item: `${SITE}/products/${slug}/` },
  ];
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: crumbs.map((c, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: c.name,
      item: c.item,
    })),
  };
}
