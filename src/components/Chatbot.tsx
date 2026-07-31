import { useState, useRef, useEffect } from 'react'

interface Message {
  role: 'user' | 'assistant' | 'system'
  content: string
}

interface RunResponse {
  success: boolean
  bucket: string
  sourceKey: string
  triggerTime: string
  confirmed: boolean
  size: number
  snUpdated: boolean
  ticketClosed: boolean
}

const DEFAULT_BUCKET = 'test-1z'
const DEFAULT_PREFIX = 'mock_logs/'

export default function Chatbot() {
  const [messages, setMessages] = useState<Message[]>([
    {
      role: 'system',
      content:
        '你好！输入告警描述，我会读取 OSS 日志并分析。\n例如：CPU 飙高，响应超时',
    },
  ])
  const [input, setInput] = useState('')
  const [loading, setLoading] = useState(false)
  const [apiKey, setApiKey] = useState('')
  const [showSettings, setShowSettings] = useState(false)
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' })
  }, [messages])

  const handleSend = async () => {
    const text = input.trim()
    if (!text || loading) return

    setInput('')
    setMessages((m) => [...m, { role: 'user', content: text }])
    setLoading(true)

    try {
      const triggerTime = new Date().toISOString()
      const body = {
        bucket: DEFAULT_BUCKET,
        prefix: DEFAULT_PREFIX,
        triggerTime,
        shortDescription: text,
        apiKey: apiKey || undefined,
      }

      const resp = await fetch('/api/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })

      if (!resp.ok) {
        const err = await resp.json().catch(() => ({}))
        throw new Error((err as { detail?: string }).detail || `请求失败 (${resp.status})`)
      }

      const data: RunResponse = await resp.json()

      let reply = `✅ 分析完成\n\n`
      reply += `- 确认持续: ${data.confirmed ? '是 (转 L2)' : '否 (自动关单)'}\n`
      reply += `- 数据量: ${data.size} 字符\n`
      if (data.snUpdated) {
        reply += data.ticketClosed ? '- 工单已自动关闭\n' : '- 已写回 ServiceNow\n'
      }
      reply += `\n触发时间: ${new Date(data.triggerTime).toLocaleString()}`

      setMessages((m) => [...m, { role: 'assistant', content: reply }])
    } catch (e) {
      setMessages((m) => [
        ...m,
        { role: 'assistant', content: `❌ ${(e as Error).message}` },
      ])
    } finally {
      setLoading(false)
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSend()
    }
  }

  return (
    <div className="flex h-screen flex-col bg-gray-50">
      {/* Header */}
      <header className="flex items-center justify-between border-b bg-white px-6 py-4 shadow-sm">
        <h1 className="text-lg font-semibold text-gray-800">AI 分析助手</h1>
        <button
          onClick={() => setShowSettings(!showSettings)}
          className="rounded-lg px-3 py-1.5 text-sm text-gray-500 hover:bg-gray-100"
        >
          {showSettings ? '完成' : '设置'}
        </button>
      </header>

      {/* Settings panel */}
      {showSettings && (
        <div className="border-b bg-white px-6 py-3">
          <label className="block text-sm text-gray-600">
            DeepSeek API Key
            <input
              type="password"
              value={apiKey}
              onChange={(e) => setApiKey(e.target.value)}
              placeholder="sk-..."
              className="mt-1 block w-full rounded-lg border px-3 py-2 text-sm outline-none focus:border-blue-400 focus:ring-1 focus:ring-blue-400"
            />
          </label>
          <p className="mt-1 text-xs text-gray-400">
            Bucket: {DEFAULT_BUCKET} / Prefix: {DEFAULT_PREFIX}
          </p>
        </div>
      )}

      {/* Messages */}
      <div ref={listRef} className="flex-1 overflow-y-auto px-6 py-4">
        <div className="mx-auto max-w-3xl space-y-4">
          {messages.map((msg, i) => (
            <div
              key={i}
              className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
            >
              <div
                className={`max-w-[75%] whitespace-pre-wrap rounded-2xl px-4 py-3 text-sm leading-relaxed ${
                  msg.role === 'user'
                    ? 'bg-blue-600 text-white'
                    : msg.role === 'system'
                      ? 'bg-gray-100 text-gray-500'
                      : 'border bg-white text-gray-800'
                }`}
              >
                {msg.content}
              </div>
            </div>
          ))}
          {loading && (
            <div className="flex justify-start">
              <div className="rounded-2xl border bg-white px-4 py-3 text-sm text-gray-400">
                分析中...
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Input */}
      <div className="border-t bg-white px-6 py-4">
        <div className="mx-auto flex max-w-3xl gap-3">
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="输入告警描述，按 Enter 发送..."
            rows={1}
            className="flex-1 resize-none rounded-xl border px-4 py-3 text-sm outline-none focus:border-blue-400 focus:ring-1 focus:ring-blue-400"
          />
          <button
            onClick={handleSend}
            disabled={loading || !input.trim()}
            className="inline-flex items-center justify-center rounded-xl bg-blue-600 px-5 py-3 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            发送
          </button>
        </div>
      </div>
    </div>
  )
}
