_ = require 'underscore'
TokenizedBuffer = require 'tokenized-buffer'
LineMap = require 'line-map'
Point = require 'point'
EventEmitter = require 'event-emitter'
Range = require 'range'
Fold = require 'fold'
ScreenLine = require 'screen-line'
Token = require 'token'

module.exports =
class DisplayBuffer
  @idCounter: 1
  lineMap: null
  languageMode: null
  tokenizedBuffer: null
  activeFolds: null
  foldsById: null
  markerScreenPositionObservers: null
  markerScreenPositions: null

  constructor: (@buffer, options={}) ->
    @id = @constructor.idCounter++
    @languageMode = options.languageMode
    @tokenizedBuffer = new TokenizedBuffer(@buffer, options)
    @softWrapColumn = options.softWrapColumn ? Infinity
    @activeFolds = {}
    @foldsById = {}
    @markerScreenPositionObservers = {}
    @markerScreenPositions = {}

    @buildLineMap()
    @tokenizedBuffer.on 'changed', (e) => @handleTokenizedBufferChange(e)

  setVisible: (visible) -> @tokenizedBuffer.setVisible(visible)

  buildLineMap: ->
    @lineMap = new LineMap
    @lineMap.insertAtScreenRow 0, @buildLinesForBufferRows(0, @buffer.getLastRow())

  triggerChanged: (eventProperties) ->
    @notifyMarkerScreenPositionObservers() unless eventProperties.bufferChange
    @trigger 'changed', eventProperties

  setSoftWrapColumn: (@softWrapColumn) ->
    start = 0
    end = @getLastRow()
    @buildLineMap()
    screenDelta = @getLastRow() - end
    bufferDelta = 0
    @triggerChanged({ start, end, screenDelta, bufferDelta })

  lineForRow: (row) ->
    @lineMap.lineForScreenRow(row)

  linesForRows: (startRow, endRow) ->
    @lineMap.linesForScreenRows(startRow, endRow)

  getLines: ->
    @lineMap.linesForScreenRows(0, @lineMap.lastScreenRow())

  bufferRowsForScreenRows: (startRow, endRow) ->
    @lineMap.bufferRowsForScreenRows(startRow, endRow)

  foldAll: ->
    for currentRow in [0..@buffer.getLastRow()]
      [startRow, endRow] = @languageMode.rowRangeForFoldAtBufferRow(currentRow) ? []
      continue unless startRow?

      @createFold(startRow, endRow)

  unfoldAll: ->
    for row in [@buffer.getLastRow()..0]
      @activeFolds[row]?.forEach (fold) => @destroyFold(fold)

  foldBufferRow: (bufferRow) ->
    for currentRow in [bufferRow..0]
      [startRow, endRow] = @languageMode.rowRangeForFoldAtBufferRow(currentRow) ? []
      continue unless startRow? and startRow <= bufferRow <= endRow
      fold = @largestFoldStartingAtBufferRow(startRow)
      continue if fold

      @createFold(startRow, endRow)

      return

  unfoldBufferRow: (bufferRow) ->
    @largestFoldContainingBufferRow(bufferRow)?.destroy()

  createFold: (startRow, endRow) ->
    return fold if fold = @foldFor(startRow, endRow)
    fold = new Fold(this, startRow, endRow)
    @registerFold(fold)

    unless @isFoldContainedByActiveFold(fold)
      bufferRange = new Range([startRow, 0], [endRow, @buffer.lineLengthForRow(endRow)])
      oldScreenRange = @screenLineRangeForBufferRange(bufferRange)

      lines = @buildLineForBufferRow(startRow)
      @lineMap.replaceScreenRows(oldScreenRange.start.row, oldScreenRange.end.row, lines)
      newScreenRange = @screenLineRangeForBufferRange(bufferRange)

      start = oldScreenRange.start.row
      end = oldScreenRange.end.row
      screenDelta = newScreenRange.end.row - oldScreenRange.end.row
      bufferDelta = 0
      @triggerChanged({ start, end, screenDelta, bufferDelta })

    fold

  isFoldContainedByActiveFold: (fold) ->
    for row, folds of @activeFolds
      for otherFold in folds
        return otherFold if fold != otherFold and fold.isContainedByFold(otherFold)

  foldFor: (startRow, endRow) ->
    _.find @activeFolds[startRow] ? [], (fold) ->
      fold.startRow == startRow and fold.endRow == endRow

  destroyFold: (fold) ->
    @unregisterFold(fold.startRow, fold)

    unless @isFoldContainedByActiveFold(fold)
      { startRow, endRow } = fold
      bufferRange = new Range([startRow, 0], [endRow, @buffer.lineLengthForRow(endRow)])
      oldScreenRange = @screenLineRangeForBufferRange(bufferRange)
      lines = @buildLinesForBufferRows(startRow, endRow)
      @lineMap.replaceScreenRows(oldScreenRange.start.row, oldScreenRange.end.row, lines)
      newScreenRange = @screenLineRangeForBufferRange(bufferRange)

      start = oldScreenRange.start.row
      end = oldScreenRange.end.row
      screenDelta = newScreenRange.end.row - oldScreenRange.end.row
      bufferDelta = 0

      @notifyMarkerScreenPositionObservers()
      @triggerChanged({ start, end, screenDelta, bufferDelta })

  destroyFoldsContainingBufferRow: (bufferRow) ->
    for row, folds of @activeFolds
      for fold in new Array(folds...)
        fold.destroy() if fold.getBufferRange().containsRow(bufferRow)

  registerFold: (fold) ->
    @activeFolds[fold.startRow] ?= []
    @activeFolds[fold.startRow].push(fold)
    @foldsById[fold.id] = fold

  unregisterFold: (bufferRow, fold) ->
    folds = @activeFolds[bufferRow]
    _.remove(folds, fold)
    delete @foldsById[fold.id]
    delete @activeFolds[bufferRow] if folds.length == 0

  largestFoldStartingAtBufferRow: (bufferRow) ->
    return unless folds = @activeFolds[bufferRow]
    (folds.sort (a, b) -> b.endRow - a.endRow)[0]

  largestFoldStartingAtScreenRow: (screenRow) ->
    @largestFoldStartingAtBufferRow(@bufferRowForScreenRow(screenRow))

  largestFoldContainingBufferRow: (bufferRow) ->
    largestFold = null
    for currentBufferRow in [bufferRow..0]
      if fold = @largestFoldStartingAtBufferRow(currentBufferRow)
        largestFold = fold if fold.endRow >= bufferRow
    largestFold

  screenLineRangeForBufferRange: (bufferRange) ->
    @expandScreenRangeToLineEnds(
      @lineMap.screenRangeForBufferRange(
        @expandBufferRangeToLineEnds(bufferRange)))

  screenRowForBufferRow: (bufferRow) ->
    @lineMap.screenPositionForBufferPosition([bufferRow, 0]).row

  lastScreenRowForBufferRow: (bufferRow) ->
    @lineMap.screenPositionForBufferPosition([bufferRow, Infinity]).row

  bufferRowForScreenRow: (screenRow) ->
    @lineMap.bufferPositionForScreenPosition([screenRow, 0]).row

  screenRangeForBufferRange: (bufferRange) ->
    @lineMap.screenRangeForBufferRange(bufferRange)

  bufferRangeForScreenRange: (screenRange) ->
    @lineMap.bufferRangeForScreenRange(screenRange)

  lineCount: ->
    @lineMap.screenLineCount()

  getLastRow: ->
    @lineCount() - 1

  maxLineLength: ->
    @lineMap.maxScreenLineLength

  screenPositionForBufferPosition: (position, options) ->
    @lineMap.screenPositionForBufferPosition(position, options)

  bufferPositionForScreenPosition: (position, options) ->
    @lineMap.bufferPositionForScreenPosition(position, options)

  scopesForBufferPosition: (bufferPosition) ->
    @tokenizedBuffer.scopesForPosition(bufferPosition)

  getTabLength: ->
    @tokenizedBuffer.getTabLength()

  setTabLength: (tabLength) ->
    @tokenizedBuffer.setTabLength(tabLength)

  clipScreenPosition: (position, options) ->
    @lineMap.clipScreenPosition(position, options)

  handleBufferChange: (e) ->
    allFolds = [] # Folds can modify @activeFolds, so first make sure we have a stable array of folds
    allFolds.push(folds...) for row, folds of @activeFolds
    fold.handleBufferChange(e) for fold in allFolds

  handleTokenizedBufferChange: (tokenizedBufferChange) ->
    if bufferChange = tokenizedBufferChange.bufferChange
      @handleBufferChange(bufferChange)
      bufferDelta = bufferChange.newRange.end.row - bufferChange.oldRange.end.row

    tokenizedBufferStart = @bufferRowForScreenRow(@screenRowForBufferRow(tokenizedBufferChange.start))
    tokenizedBufferEnd = tokenizedBufferChange.end
    tokenizedBufferDelta = tokenizedBufferChange.delta

    start = @screenRowForBufferRow(tokenizedBufferStart)
    end = @lastScreenRowForBufferRow(tokenizedBufferEnd)
    newScreenLines = @buildLinesForBufferRows(tokenizedBufferStart, tokenizedBufferEnd + tokenizedBufferDelta)
    @lineMap.replaceScreenRows(start, end, newScreenLines)
    screenDelta = @lastScreenRowForBufferRow(tokenizedBufferEnd + tokenizedBufferDelta) - end

    @triggerChanged({ start, end, screenDelta, bufferDelta })

  buildLineForBufferRow: (bufferRow) ->
    @buildLinesForBufferRows(bufferRow, bufferRow)

  buildLinesForBufferRows: (startBufferRow, endBufferRow) ->
    lineFragments = []
    startBufferColumn = null
    currentBufferRow = startBufferRow
    currentScreenLineLength = 0

    startBufferColumn = 0
    while currentBufferRow <= endBufferRow
      screenLine = @tokenizedBuffer.lineForScreenRow(currentBufferRow)

      if fold = @largestFoldStartingAtBufferRow(currentBufferRow)
        screenLine = screenLine.copy()
        screenLine.fold = fold
        screenLine.bufferRows = fold.getBufferRowCount()
        lineFragments.push(screenLine)
        currentBufferRow = fold.endRow + 1
        continue

      startBufferColumn ?= 0
      screenLine = screenLine.softWrapAt(startBufferColumn)[1] if startBufferColumn > 0
      wrapScreenColumn = @findWrapColumn(screenLine.text, @softWrapColumn)
      if wrapScreenColumn?
        screenLine = screenLine.softWrapAt(wrapScreenColumn)[0]
        screenLine.screenDelta = new Point(1, 0)
        startBufferColumn += wrapScreenColumn
      else
        currentBufferRow++
        startBufferColumn = 0

      lineFragments.push(screenLine)

    lineFragments

  findWrapColumn: (line, softWrapColumn) ->
    return unless line.length > softWrapColumn

    if /\s/.test(line[softWrapColumn])
      # search forward for the start of a word past the boundary
      for column in [softWrapColumn..line.length]
        return column if /\S/.test(line[column])
      return line.length
    else
      # search backward for the start of the word on the boundary
      for column in [softWrapColumn..0]
        return column + 1 if /\s/.test(line[column])
      return softWrapColumn

  expandScreenRangeToLineEnds: (screenRange) ->
    screenRange = Range.fromObject(screenRange)
    { start, end } = screenRange
    new Range([start.row, 0], [end.row, @lineMap.lineForScreenRow(end.row).text.length])

  expandBufferRangeToLineEnds: (bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    { start, end } = bufferRange
    new Range([start.row, 0], [end.row, Infinity])

  rangeForAllLines: ->
    new Range([0, 0], @clipScreenPosition([Infinity, Infinity]))

  markScreenRange: (screenRange) ->
    @markBufferRange(@bufferRangeForScreenRange(screenRange))

  markBufferRange: (args...) ->
    @buffer.markRange(args...)

  markScreenPosition: (screenPosition, options) ->
    @markBufferPosition(@bufferPositionForScreenPosition(screenPosition), options)

  markBufferPosition: (bufferPosition, options) ->
    @buffer.markPosition(bufferPosition, options)

  destroyMarker: (id) ->
    @buffer.destroyMarker(id)
    delete @markerScreenPositionObservers[id]
    delete @markerScreenPositions[id]

  getMarkerScreenRange: (id) ->
    @screenRangeForBufferRange(@getMarkerBufferRange(id), wrapAtSoftNewlines: true)

  setMarkerScreenRange: (id, screenRange, options) ->
    @setMarkerBufferRange(id, @bufferRangeForScreenRange(screenRange), options)

  getMarkerBufferRange: (id) ->
    @buffer.getMarkerRange(id)

  setMarkerBufferRange: (id, bufferRange, options) ->
    @buffer.setMarkerRange(id, bufferRange, options)

  getMarkerScreenPosition: (id) ->
    @getMarkerHeadScreenPosition(id)

  getMarkerBufferPosition: (id) ->
    @getMarkerHeadBufferPosition(id)

  getMarkerHeadScreenPosition: (id) ->
    @screenPositionForBufferPosition(@getMarkerHeadBufferPosition(id), wrapAtSoftNewlines: true)

  setMarkerHeadScreenPosition: (id, screenPosition, options) ->
    screenPosition = @clipScreenPosition(screenPosition, options)
    @setMarkerHeadBufferPosition(id, @bufferPositionForScreenPosition(screenPosition, options))

  getMarkerHeadBufferPosition: (id) ->
    @buffer.getMarkerHeadPosition(id)

  setMarkerHeadBufferPosition: (id, bufferPosition) ->
    @buffer.setMarkerHeadPosition(id, bufferPosition)

  getMarkerTailScreenPosition: (id) ->
    @screenPositionForBufferPosition(@getMarkerTailBufferPosition(id), wrapAtSoftNewlines: true)

  setMarkerTailScreenPosition: (id, screenPosition, options) ->
    screenPosition = @clipScreenPosition(screenPosition, options)
    @setMarkerTailBufferPosition(id, @bufferPositionForScreenPosition(screenPosition, options))

  getMarkerTailBufferPosition: (id) ->
    @buffer.getMarkerTailPosition(id)

  setMarkerTailBufferPosition: (id, bufferPosition) ->
    @buffer.setMarkerTailPosition(id, bufferPosition)

  placeMarkerTail: (id) ->
    @buffer.placeMarkerTail(id)

  clearMarkerTail: (id) ->
    @buffer.clearMarkerTail(id)

  isMarkerReversed: (id) ->
    @buffer.isMarkerReversed(id)

  observeMarkerHeadScreenPosition: (id, callback) ->
    @markerScreenPositionObservers[id] ?= { head: [], tail: [] }
    @cacheMarkerScreenPositions(id) unless @markerScreenPositions[id]
    @markerScreenPositionObservers[id].head.push(callback)
    subscription = @buffer.observeMarkerHeadPosition id, (e) =>
      bufferChanged = e.bufferChanged
      oldBufferPosition = e.oldPosition
      newBufferPosition = e.newPosition
      oldScreenPosition = @markerScreenPositions[id].head
      @cacheMarkerScreenPositions(id)
      newScreenPosition = @getMarkerHeadScreenPosition(id)
      callback({ oldBufferPosition, newBufferPosition, oldScreenPosition, newScreenPosition, bufferChanged })

    cancel: =>
      subscription.cancel()
      { head, tail } = @markerScreenPositionObservers[id]
      _.remove(head, callback)
      unless head.length + tail.length
        delete @markerScreenPositionObservers[id]
        delete @markerScreenPositions[id]

  cacheMarkerScreenPositions: (id) ->
    @markerScreenPositions[id] = { head: @getMarkerHeadScreenPosition(id), tail: @getMarkerTailScreenPosition }

  notifyMarkerScreenPositionObservers: ->
    for id, { head } of @markerScreenPositions
      currentHeadPosition = @getMarkerHeadScreenPosition(id)
      unless currentHeadPosition.isEqual(head)
        bufferChanged = false
        oldBufferPosition = newBufferPosition = @buffer.getMarkerHeadPosition(id)
        oldScreenPosition = @markerScreenPositions[id].head
        @cacheMarkerScreenPositions(id)
        newScreenPosition = @getMarkerHeadScreenPosition(id)
        for observer in @markerScreenPositionObservers[id].head
          observer({oldScreenPosition, newScreenPosition, oldBufferPosition, newBufferPosition, bufferChanged})

  destroy: ->
    @tokenizedBuffer.destroy()

  logLines: (start, end) ->
    @lineMap.logLines(start, end)

_.extend DisplayBuffer.prototype, EventEmitter
