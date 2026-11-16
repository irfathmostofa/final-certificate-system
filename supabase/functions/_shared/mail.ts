// Shared helpers: Resend email + simple HTML template + service client.
import { createClient } from 'npm:@supabase/supabase-js@2'

export const admin = () =>
  createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false }
  })

export const esc = (v: unknown) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

export async function secretOk(req: Request): Promise<boolean> {
  const secret = req.headers.get('x-certify-secret') || ''
  if (!secret) return false
  const { data, error } = await admin().rpc('bridge_check_secret', { p_secret: secret })
  return !error && data === true
}

export async function sendMail(to: string, subject: string, html: string) {
  const key = Deno.env.get('RESEND_API_KEY')
  const from = Deno.env.get('MAIL_FROM')
  if (!key || !from) throw new Error('RESEND_API_KEY and MAIL_FROM must be set.')
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject, html })
  })
  if (!res.ok) throw new Error(`Resend error ${res.status}: ${await res.text()}`)
}

export function mailHtml(title: string, introHtml: string, buttonLabel: string, url: string, footerHtml = '') {
  const org = esc(Deno.env.get('ORG_NAME') || '')
  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;padding:24px;color:#111827">
<h2 style="margin:0 0 16px">${esc(title)}</h2>${introHtml}
<p style="margin:24px 0"><a href="${esc(url)}" style="background:#2563eb;color:#fff;text-decoration:none;padding:12px 22px;border-radius:8px;font-weight:bold;display:inline-block">${esc(buttonLabel)}</a></p>
<p style="font-size:13px;color:#6b7280;word-break:break-all">${esc(url)}</p>${footerHtml}
${org ? `<p style="font-size:13px;color:#6b7280;margin-top:24px">— ${org}</p>` : ''}</div>`
}

export const appUrl = () => (Deno.env.get('APP_URL') || '').replace(/\/+$/, '')
