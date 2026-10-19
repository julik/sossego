import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
import SossegoController from "@julik/sossego-stimulus"
import SossegoHighlightController from "@julik/sossego-highlight"

application.register("sossego", SossegoController)
application.register("sossego-highlight", SossegoHighlightController)
eagerLoadControllersFrom("controllers", application)

