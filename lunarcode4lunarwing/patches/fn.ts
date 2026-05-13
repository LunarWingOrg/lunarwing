import { z } from "zod"

export function fn<T extends z.ZodType, Result>(schema: T, cb: (input: z.infer<T>) => Result) {
  const result = (input: z.infer<T>) => {
    const parsed = schema.safeParse(input)
    if (!parsed.success) {
      console.warn("schema validation failed, continuing with raw input:", parsed.error.issues.map((i: z.ZodIssue) => i.message).join(", "))
      return cb(input)
    }
    return cb(parsed.data)
  }
  result.force = (input: z.infer<T>) => cb(input)
  result.schema = schema
  return result
}
