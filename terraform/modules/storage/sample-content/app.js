/**
 * ScaleCommerce — Frontend Client
 * Simple vanilla JS frontend served from S3/CloudFront.
 */

const API_BASE = '/api';

async function fetchProducts() {
  const container = document.getElementById('products');
  if (!container) return;

  container.innerHTML = '<p>Loading products...</p>';

  try {
    const response = await fetch(`${API_BASE}/products`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const products = await response.json();

    if (products.length === 0) {
      container.innerHTML = '<p>No products available.</p>';
      return;
    }

    container.innerHTML = products
      .map(p => `
        <div class="product-card" data-id="${p.id}">
          <h3>${escapeHtml(p.name)}</h3>
          <p class="price">$${Number(p.price).toFixed(2)}</p>
          <button onclick="addToCart(${p.id}, '${escapeHtml(p.name)}')">Add to Cart</button>
        </div>
      `)
      .join('');
  } catch (err) {
    container.innerHTML = `<p class="error">Failed to load products: ${escapeHtml(err.message)}</p>`;
  }
}

async function addToCart(productId, productName) {
  const email = prompt('Enter your email to place an order:');
  if (!email) return;

  try {
    const response = await fetch(`${API_BASE}/orders`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ product_id: productId, quantity: 1, customer_email: email })
    });

    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const { order_id } = await response.json();
    alert(`Order #${order_id} placed for "${productName}"`);
  } catch (err) {
    alert(`Failed to place order: ${err.message}`);
  }
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

document.addEventListener('DOMContentLoaded', fetchProducts);
