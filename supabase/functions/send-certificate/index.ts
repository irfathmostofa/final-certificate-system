// Emails certificates for students who passed. Triggered by Supabase (pg_net) right
// after a pass, and optionally by a pg_cron schedule as a safety net.
import { admin, appUrl, esc, json, mailHtml, secretOk, sendMail } from '../_shared/mail.ts'

Deno.serve(async (req) => {
  if (!(await secretOk(req))) return json({ ok: false, message: 'Unauthorized.' }, 401)

  const sb = admin()
  const secret = req.headers.get('x-certify-secret')!
  const { data: rows, error } = await sb.rpc('bridge_pending_certificates', { p_secret: secret })
  if (error) {
    console.error(error)
    return json({ ok: false, message: error.message }, 500)
  }

  let sent = 0
  const failed: string[] = []
  for (const row of rows || []) {
    try {
      const url = `${appUrl()}/view/${encodeURIComponent(row.publicToken)}`
      const intro = `<p>Congratulations ${esc(row.name)}!</p>
<p>You passed the exam for <strong>${esc(row.courseTitle)}</strong> with a score of ${esc(row.score)} / ${esc(row.totalMarks)}.</p>
<p>Your certificate is ready. Open it to view, verify and download it as PDF or image.</p>`
      const foot = `<p style="font-size:13px;color:#6b7280">Certificate ID: ${esc(row.certificateId)}</p>`
      await sendMail(row.email, `Your certificate — ${row.courseTitle}`, mailHtml('Your certificate is ready', intro, 'View certificate', url, foot))
      await sb.rpc('bridge_mark_certificate_emailed', { p_secret: secret, p_attempt_id: row.attemptId })
      sent++
    } catch (e) {
      console.error(e)
      failed.push(row.attemptId)
    }
  }
  return json({ ok: true, sent, failed })
})
