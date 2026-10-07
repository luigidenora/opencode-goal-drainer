export default {
  id: "probe-bad-transform",
  setup: async (input: any) => {
    // `transform` prende una callback: passargli `{}` fa fallire il plugin
    input.command.transform({} as any)
    input.tool.transform({} as any)
    return {}
  },
}
