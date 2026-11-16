// Called server-to-server by the WordPress plugin after it verified enrollment.
// Creates a one-time exam invitation and emails the link through Resend.
import { admin, appUrl, esc, json, mailHtml, secretOk, sendMail } from '../_shared/mail.ts'

const sha256 = async (text: string) =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')

const ERRORS: Record<string, string> = {
  no_exam: 'No exam has been set up for this course yet.',
  no_questions: 'The exam for this course is not ready yet.',
  already_passed: 'You have already passed this exam. Your certificate was sent to your email.',
  in_progress: 'You have an exam in progress. Finish it using your original link.',
  unauthorized: 'The exam service is not configured correctly.'
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, message: 'Method not allowed.' }, 405)
  if (!(await secretOk(req))) return json({ ok: false, message: 'Unauthorized.' }, 401)

  let body: Record<string, string>
  try {
    body = await req.json()
  } catch {
    return json({ ok: false, message: 'Invalid request.' }, 400)
  }
  const { course_id, user_id, name, email, exam_id } = body
  if (!course_id || !user_id || !name || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email || '')) {
    return json({ ok: false, message: 'Invalid request.' }, 400)
  }

  const bytes = crypto.getRandomValues(new Uint8Array(24))
  const token = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('')

  const sb = admin()
  const secret = req.headers.get('x-certify-secret')!
  const { data, error } = await sb.rpc('bridge_request_exam_invitation', {
    p_secret: secret,
    p_wp_course_id: String(course_id),
    p_wp_user_id: String(user_id),
    p_name: name,
    p_email: email,
    p_token_hash: await sha256(token),
    p_exam_id: String(exam_id || '')
  })
  if (error) {
    console.error(error)
    return json({ ok: false, message: 'The exam service is unavailable. Please try again later.' }, 500)
  }
  if (!data?.ok) return json({ ok: false, message: ERRORS[data?.error] || 'Could not create your exam link.' })

  const link = `${appUrl()}/exam/${token}`
  const intro = `<p>Hi ${esc(name)},</p>
<p>Here is your exam link for <strong>${esc(data.courseTitle)}</strong> (${esc(data.examTitle)}).</p>
<ul><li>Duration: <strong>${esc(data.durationMinutes)} minutes</strong></li>
<li>Pass mark: <strong>${esc(data.passMarks)} / ${esc(data.totalMarks)}</strong></li></ul>`
  const foot = `<p style="font-size:14px">This link works <strong>once</strong>. The timer starts when you open it, and leaving the exam page can void your attempt. If you pass, your certificate is emailed to you automatically.</p>`

  try {
    await sendMail(email, `Your exam link — ${data.courseTitle}`, mailHtml('Your exam is ready', intro, 'Start exam', link, foot))
  } catch (e) {
    console.error(e)
    // Revoke the unusable link so the student can simply apply again.
    await sb.from('exam_invitations').update({ status: 'revoked' }).eq('token_hash', await sha256(token))
    return json({ ok: false, message: 'We could not send the email. Please try again later.' }, 502)
  }
  return json({ ok: true, message: `Your exam link has been sent to ${email}. Please check your inbox (and spam folder).` })
})
