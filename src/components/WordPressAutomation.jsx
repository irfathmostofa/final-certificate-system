import { useEffect, useState } from 'react'
import { getBridgeConfig, saveBridgeNotifyUrl } from '../lib/exams.js'
import { isSupabaseConfigured } from '../lib/supabase.js'

export default function WordPressAutomation() {
  const [config, setConfig] = useState({ secret: '', notifyUrl: '' })
  const [loading, setLoading] = useState(isSupabaseConfigured)
  const [saving, setSaving] = useState(false)
  const [msg, setMsg] = useState(null)

  useEffect(() => {
    if (!isSupabaseConfigured) return undefined
    let active = true
    getBridgeConfig()
      .then((value) => active && setConfig(value))
      .catch((e) =>
        active &&
        setMsg({
          type: 'error',
          text: `${e.message || 'Could not load.'} Run supabase/migrations/20261116_auto_exam_flow.sql first.`
        })
      )
      .finally(() => active && setLoading(false))
    return () => {
      active = false
    }
  }, [])

  const copy = async (text) => {
    try {
      await navigator.clipboard.writeText(text)
      setMsg({ type: 'success', text: 'Copied.' })
    } catch {
      setMsg({ type: 'error', text: 'Copy failed. Select the text and copy it manually.' })
    }
  }

  const save = async () => {
    setSaving(true)
    setMsg(null)
    try {
      await saveBridgeNotifyUrl(config.notifyUrl)
      setMsg({ type: 'success', text: 'Function URL saved.' })
    } catch (e) {
      setMsg({ type: 'error', text: e.message || 'Could not save.' })
    } finally {
      setSaving(false)
    }
  }

  if (!isSupabaseConfigured) {
    return (
      <div className="alert info">
        Automatic exam links and certificates need Supabase. Connect it first (see README).
      </div>
    )
  }
  if (loading) return <div className="muted">Loading…</div>

  return (
    <>
      <h3 style={{ marginTop: 0 }}>WordPress automation</h3>
      <p className="muted small" style={{ marginTop: 6 }}>
        Deploy the <code>request-exam</code> and <code>send-certificate</code> Supabase Edge Functions (emails go
        through Resend), then enter your Supabase URL and this secret in WordPress → Settings → Certify Exam Bridge.
        Instructors add <code>[certify_exam_apply]</code> to a Tutor course.
      </p>
      {msg && <div className={`alert ${msg.type}`}>{msg.text}</div>}
      <div className="field">
        <label>Bridge secret</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="input" readOnly value={config.secret} />
          <button type="button" className="btn btn-ghost" onClick={() => copy(config.secret)} disabled={!config.secret}>
            Copy
          </button>
        </div>
        <p className="muted small" style={{ margin: '6px 0 0' }}>Keep this private. It authorises WordPress to create exam links.</p>
      </div>
      <div className="field">
        <label>send-certificate function URL (instant certificate email)</label>
        <input
          className="input"
          value={config.notifyUrl}
          onChange={(e) => setConfig((c) => ({ ...c, notifyUrl: e.target.value }))}
          placeholder="https://YOUR-PROJECT.supabase.co/functions/v1/send-certificate"
        />
        <p className="muted small" style={{ margin: '6px 0 0' }}>
          Needs the pg_net extension. Without it, certificates are emailed when the optional pg_cron job (see the migration) runs.
        </p>
      </div>
      <button type="button" className="btn btn-primary" onClick={save} disabled={saving}>
        {saving ? 'Saving…' : 'Save function URL'}
      </button>
    </>
  )
}
