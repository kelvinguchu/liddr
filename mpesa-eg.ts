// type MpesaConfig = {
//   baseURL: string
//   consumerKey: string
//   consumerSecret: string
//   shortcode: string
//   passkey: string
// }

// type STKRequestInput = {
//   amount: number
//   phone: string
//   callbackURL: string
//   accountReference: string
//   transactionDesc: string
// }

// type TransactionStatusInput = {
//   transactionID: string
//   resultURL: string
//   timeoutURL: string
//   remarks?: string
//   occasion?: string
// }

// const getEnv = (key: string) => {
//   const value = process.env[key]
//   if (!value) {
//     throw new Error(`Missing required env var: ${key}`)
//   }
//   return value
// }

// const getConfig = (): MpesaConfig => {
//   const mpesaEnv = process.env.MPESA_ENV === 'production' ? 'production' : 'sandbox'

//   return {
//     baseURL:
//       process.env.MPESA_BASE_URL ||
//       (mpesaEnv === 'production'
//         ? 'https://api.safaricom.co.ke'
//         : 'https://sandbox.safaricom.co.ke'),
//     consumerKey: getEnv('MPESA_CONSUMER_KEY'),
//     consumerSecret: getEnv('MPESA_CONSUMER_SECRET'),
//     shortcode: getEnv('MPESA_SHORTCODE'),
//     passkey: getEnv('MPESA_PASSKEY'),
//   }
// }

// const formatTimestamp = (date: Date) => {
//   const y = date.getFullYear().toString()
//   const m = String(date.getMonth() + 1).padStart(2, '0')
//   const d = String(date.getDate()).padStart(2, '0')
//   const hh = String(date.getHours()).padStart(2, '0')
//   const mm = String(date.getMinutes()).padStart(2, '0')
//   const ss = String(date.getSeconds()).padStart(2, '0')

//   return `${y}${m}${d}${hh}${mm}${ss}`
// }

// const buildTimestamp = () => {
//   const kenyaDate = new Date(new Date().toLocaleString('en-US', { timeZone: 'Africa/Nairobi' }))
//   return formatTimestamp(kenyaDate)
// }

// const toBasicAuth = (key: string, secret: string) =>
//   Buffer.from(`${key}:${secret}`).toString('base64')

// const sanitizePhone = (rawPhone: string): string => {
//   const digits = rawPhone.replaceAll(/\D/g, '')

//   if (digits.startsWith('254') && digits.length === 12) return digits
//   if (digits.startsWith('0') && digits.length === 10) return `254${digits.slice(1)}`
//   if (digits.startsWith('7') && digits.length === 9) return `254${digits}`

//   throw new Error('Invalid phone format. Use a Kenyan Safaricom number like 07XXXXXXXX.')
// }

// const getAccessToken = async () => {
//   const config = getConfig()

//   console.log('[M-Pesa Auth] Requesting access token...')

//   const response = await fetch(
//     `${config.baseURL}/oauth/v1/generate?grant_type=client_credentials`,
//     {
//       headers: {
//         Authorization: `Basic ${toBasicAuth(config.consumerKey, config.consumerSecret)}`,
//       },
//     },
//   )

//   if (!response.ok) {
//     const text = await response.text()
//     console.error('[M-Pesa Auth] Token request failed:', response.status, text)
//     throw new Error(`M-Pesa token request failed (${response.status}): ${text}`)
//   }

//   const data = (await response.json()) as { access_token: string }

//   if (!data?.access_token) {
//     console.error('[M-Pesa Auth] No access_token in response:', JSON.stringify(data))
//     throw new Error('M-Pesa token response did not include access_token')
//   }

//   console.log('[M-Pesa Auth] Token acquired successfully')

//   return data.access_token
// }

// export const initiateSTKPush = async (input: STKRequestInput) => {
//   const config = getConfig()
//   const token = await getAccessToken()
//   const timestamp = buildTimestamp()
//   const phone = sanitizePhone(input.phone)
//   const amount = Math.max(1, Math.round(input.amount))
//   const password = Buffer.from(`${config.shortcode}${config.passkey}${timestamp}`).toString(
//     'base64',
//   )

//   const payload = {
//     BusinessShortCode: config.shortcode,
//     Password: password,
//     Timestamp: timestamp,
//     TransactionType: 'CustomerPayBillOnline',
//     Amount: amount,
//     PartyA: phone,
//     PartyB: config.shortcode,
//     PhoneNumber: phone,
//     CallBackURL: input.callbackURL,
//     AccountReference: input.accountReference,
//     TransactionDesc: input.transactionDesc,
//   }

//   console.log('[M-Pesa STK] Request:', JSON.stringify(payload, null, 2))

//   const response = await fetch(`${config.baseURL}/mpesa/stkpush/v1/processrequest`, {
//     method: 'POST',
//     headers: {
//       Authorization: `Bearer ${token}`,
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify(payload),
//   })

//   const responseBody = await response.json()

//   console.log('[M-Pesa STK] Response:', response.status, JSON.stringify(responseBody, null, 2))

//   if (!response.ok) {
//     console.error('[M-Pesa STK] Failed:', response.status, JSON.stringify(responseBody))
//     throw new Error(
//       `M-Pesa STK request failed (${response.status}): ${JSON.stringify(responseBody)}`,
//     )
//   }

//   return {
//     requestPayload: payload,
//     responsePayload: responseBody,
//   }
// }

// export type STKQueryResult = {
//   resultCode: number
//   resultDesc: string
//   merchantRequestID?: string
//   checkoutRequestID?: string
//   responsePayload: unknown
// }

// export const querySTKStatus = async (checkoutRequestID: string): Promise<STKQueryResult> => {
//   const config = getConfig()
//   const token = await getAccessToken()
//   const timestamp = buildTimestamp()
//   const password = Buffer.from(`${config.shortcode}${config.passkey}${timestamp}`).toString(
//     'base64',
//   )

//   const payload = {
//     BusinessShortCode: config.shortcode,
//     Password: password,
//     Timestamp: timestamp,
//     CheckoutRequestID: checkoutRequestID,
//   }

//   console.log('[M-Pesa STK Query] Request for:', checkoutRequestID)

//   const response = await fetch(`${config.baseURL}/mpesa/stkpushquery/v1/query`, {
//     method: 'POST',
//     headers: {
//       Authorization: `Bearer ${token}`,
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify(payload),
//   })

//   const body = (await response.json()) as {
//     ResultCode?: number | string
//     ResultDesc?: string
//     MerchantRequestID?: string
//     CheckoutRequestID?: string
//   }

//   console.log('[M-Pesa STK Query] Response:', response.status, JSON.stringify(body, null, 2))

//   return {
//     resultCode: Number(body.ResultCode ?? -1),
//     resultDesc: body.ResultDesc ?? '',
//     merchantRequestID: body.MerchantRequestID || undefined,
//     checkoutRequestID: body.CheckoutRequestID || undefined,
//     responsePayload: body,
//   }
// }

// export const registerC2BUrls = async (validationURL: string, confirmationURL: string) => {
//   const config = getConfig()
//   const token = await getAccessToken()
//   const commandID = process.env.MPESA_C2B_COMMAND_ID || 'CustomerPayBillOnline'

//   const payload = {
//     ShortCode: config.shortcode,
//     ResponseType: 'Completed',
//     ConfirmationURL: confirmationURL,
//     ValidationURL: validationURL,
//     CommandID: commandID,
//   }

//   const response = await fetch(`${config.baseURL}/mpesa/c2b/v1/registerurl`, {
//     method: 'POST',
//     headers: {
//       Authorization: `Bearer ${token}`,
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify(payload),
//   })

//   const responseBody = await response.json()

//   if (!response.ok) {
//     throw new Error(
//       `M-Pesa C2B URL registration failed (${response.status}): ${JSON.stringify(responseBody)}`,
//     )
//   }

//   return responseBody
// }

// export const queryTransactionStatus = async (input: TransactionStatusInput) => {
//   const config = getConfig()
//   const token = await getAccessToken()

//   const initiatorName = getEnv('MPESA_INITIATOR_NAME')
//   const securityCredential = getEnv('MPESA_SECURITY_CREDENTIAL')
//   const identifierType = Number(process.env.MPESA_IDENTIFIER_TYPE || '4')
//   const commandID = process.env.MPESA_TRANSACTION_STATUS_COMMAND_ID || 'TransactionStatusQuery'

//   const payload = {
//     Initiator: initiatorName,
//     SecurityCredential: securityCredential,
//     CommandID: commandID,
//     TransactionID: input.transactionID,
//     PartyA: config.shortcode,
//     IdentifierType: identifierType,
//     ResultURL: input.resultURL,
//     QueueTimeOutURL: input.timeoutURL,
//     Remarks: input.remarks || 'Order reconciliation',
//     Occasion: input.occasion || 'OrderPaymentStatus',
//   }

//   const response = await fetch(`${config.baseURL}/mpesa/transactionstatus/v1/query`, {
//     method: 'POST',
//     headers: {
//       Authorization: `Bearer ${token}`,
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify(payload),
//   })

//   const responseBody = await response.json()

//   if (!response.ok) {
//     throw new Error(
//       `M-Pesa transaction status query failed (${response.status}): ${JSON.stringify(responseBody)}`,
//     )
//   }

//   return {
//     requestPayload: payload,
//     responsePayload: responseBody,
//   }
// }

// export type ParsedSTKCallback = {
//   merchantRequestID: string
//   checkoutRequestID: string
//   resultCode: number
//   resultDesc: string
//   amount: number
//   mpesaReceiptNumber: string
//   transactionDate: string
//   phoneNumber: string
// }

// export const parseSTKCallback = (payload: unknown): ParsedSTKCallback | null => {
//   const body = payload as {
//     Body?: {
//       stkCallback?: {
//         MerchantRequestID?: string
//         CheckoutRequestID?: string
//         ResultCode?: number
//         ResultDesc?: string
//         CallbackMetadata?: {
//           Item?: { Name?: string; Value?: string | number }[]
//         }
//       }
//     }
//   }

//   const callback = body?.Body?.stkCallback
//   if (!callback) return null

//   const metadata = Array.isArray(callback.CallbackMetadata?.Item)
//     ? callback.CallbackMetadata?.Item
//     : []

//   const pick = (name: string) => metadata.find((item) => item?.Name === name)?.Value

//   return {
//     merchantRequestID: callback.MerchantRequestID || '',
//     checkoutRequestID: callback.CheckoutRequestID || '',
//     resultCode: Number(callback.ResultCode || 0),
//     resultDesc: callback.ResultDesc || '',
//     amount: Number(pick('Amount') || 0),
//     mpesaReceiptNumber: String(pick('MpesaReceiptNumber') || ''),
//     transactionDate: String(pick('TransactionDate') || ''),
//     phoneNumber: String(pick('PhoneNumber') || ''),
//   }
// }

// export const parseC2BPayload = (payload: unknown) => {
//   const body = payload as {
//     TransID?: string
//     TransAmount?: string | number
//     BillRefNumber?: string
//     MSISDN?: string
//     FirstName?: string
//     MiddleName?: string
//     LastName?: string
//     TransTime?: string
//   }

//   return {
//     transID: body?.TransID || '',
//     amount: Number(body?.TransAmount || 0),
//     billRefNumber: body?.BillRefNumber || '',
//     msisdn: body?.MSISDN || '',
//     firstName: body?.FirstName || '',
//     middleName: body?.MiddleName || '',
//     lastName: body?.LastName || '',
//     transTime: body?.TransTime || '',
//   }
// }

// export const parseTransactionStatusCallback = (payload: unknown) => {
//   const body = payload as {
//     Result?: {
//       ResultType?: number
//       ResultCode?: number
//       ResultDesc?: string
//       OriginatorConversationID?: string
//       ConversationID?: string
//       TransactionID?: string
//     }
//   }

//   const result = body?.Result
//   if (!result) return null

//   return {
//     resultType: Number(result.ResultType || 0),
//     resultCode: Number(result.ResultCode || 0),
//     resultDesc: String(result.ResultDesc || ''),
//     originatorConversationID: String(result.OriginatorConversationID || ''),
//     conversationID: String(result.ConversationID || ''),
//     transactionID: String(result.TransactionID || ''),
//   }
// }

// export const normalizeMpesaPhone = sanitizePhone
