// POST /nostromo/invite — create a user account with a server-generated password.
//
// Authorization: superuser only ($apis.requireSuperuserAuth()). On a shared
// multi-app instance, letting any authenticated caller invite would allow one
// app's user to mint accounts, so account creation stays deliberate.
//
// Body:     { email, name? }
// Response: { email, userId, created: true, password }   first creation
//           { email, userId, created: false }            email already invited
//
// The password is returned exactly once, in this response, and is never sent by
// mail (v1 has no SMTP). The invite stops at user creation: no groups and no
// document_access rows are written.
//
// NB! PB hook callbacks run in an isolated scope: everything below is inlined
// inside the routerAdd handler.

routerAdd(
  'POST',
  '/nostromo/invite',
  (c) => {
    const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    const PASSWORD_LENGTH = 16
    const PASSWORD_ALPHABET =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    const MAX_NAME_LENGTH = 200

    const body = c.requestInfo().body
    const email = String(body.email || '').trim().toLowerCase()
    if (!EMAIL_PATTERN.test(email)) {
      throw new ApiError(400, 'invalid email: expected a well-formed email address')
    }

    // Idempotent on email: an existing account is returned as-is, without a
    // password (the caller must never learn or reset it).
    let existingUser = null
    try {
      existingUser = $app.findAuthRecordByEmail('users', email)
    } catch {
      existingUser = null
    }
    if (existingUser) {
      return c.json(200, { email, userId: existingUser.id, created: false })
    }

    const password = $security.randomString(PASSWORD_LENGTH, PASSWORD_ALPHABET)
    const name = String(body.name || '').trim().slice(0, MAX_NAME_LENGTH)

    const user = new Record($app.findCollectionByNameOrId('users'))
    user.set('email', email)
    user.set('password', password)
    if (name) {
      user.set('name', name)
    }
    try {
      $app.save(user)
    } catch (err) {
      throw new ApiError(400, `failed to create user: ${err}`)
    }

    return c.json(200, { email, userId: user.id, created: true, password })
  },
  $apis.requireSuperuserAuth(),
)
