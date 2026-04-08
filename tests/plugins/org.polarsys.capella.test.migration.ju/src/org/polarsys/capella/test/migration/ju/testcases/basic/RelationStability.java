/*******************************************************************************
 * Copyright (c) 2024 THALES GLOBAL SERVICES.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0
 * 
 * SPDX-License-Identifier: EPL-2.0
 * 
 * Contributors:
 *    Thales - initial API and implementation
 *******************************************************************************/
package org.polarsys.capella.test.migration.ju.testcases.basic;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.function.Supplier;
import java.util.stream.Stream;

import org.eclipse.core.resources.IProject;
import org.eclipse.draw2d.Connection;
import org.eclipse.draw2d.geometry.Dimension;
import org.eclipse.draw2d.geometry.Point;
import org.eclipse.draw2d.geometry.PointList;
import org.eclipse.draw2d.geometry.Rectangle;
import org.eclipse.gef.GraphicalEditPart;
import org.eclipse.gmf.runtime.notation.Bendpoints;
import org.eclipse.gmf.runtime.notation.Edge;
import org.eclipse.gmf.runtime.notation.RelativeBendpoints;
import org.eclipse.sirius.business.api.session.Session;
import org.eclipse.sirius.diagram.DDiagram;
import org.eclipse.sirius.diagram.DDiagramElement;
import org.eclipse.sirius.diagram.DEdge;
import org.eclipse.sirius.diagram.EdgeArrows;
import org.eclipse.sirius.diagram.ui.business.api.view.SiriusGMFHelper;
import org.eclipse.sirius.diagram.ui.internal.edit.parts.DEdgeBeginNameEditPart;
import org.eclipse.sirius.diagram.ui.internal.edit.parts.DEdgeEndNameEditPart;
import org.eclipse.sirius.diagram.ui.internal.edit.parts.DEdgeNameEditPart;
import org.eclipse.swt.SWT;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import org.polarsys.capella.core.data.capellacore.Classifier;
import org.polarsys.capella.core.data.information.AggregationKind;
import org.polarsys.capella.core.data.information.Association;
import org.polarsys.capella.core.sirius.analysis.DiagramServices;
import org.polarsys.capella.test.diagram.common.ju.api.AbstractDiagramTestCase;
import org.polarsys.capella.test.diagram.common.ju.context.CDBDiagram;
import org.polarsys.capella.test.diagram.common.ju.wrapper.utils.DiagramHelper;
import org.polarsys.capella.test.framework.context.SessionContext;
import org.polarsys.capella.test.framework.helpers.GuiActions;
import org.polarsys.capella.test.framework.helpers.IResourceHelpers;
import org.polarsys.capella.test.migration.ju.helpers.MigrationHelper;

import junit.framework.AssertionFailedError;

/**
 * This class tests the migration of the association relation in the cdb diagram.
 * 
 * @author Séraphin Costa
 */
@RunWith(value = Parameterized.class)
public class RelationStability extends AbstractDiagramTestCase {

  public static final String DEBUG_REVISION = "relation-debug-2026-04-08T16:55Z-r1";
  private static final String DIAGRAM_NAME = "[CDB] Data";
  private static final String FILTER_PROPERTY = "capella.test.migration.relation.filter";
  private static final String TRACE_PROPERTY = "capella.test.migration.relation.trace";
  private static final String PERTURBATION_PROPERTY = "capella.test.migration.relation.perturbation";
  private static final String PERTURBATION_ROUNDS_PROPERTY = "capella.test.migration.relation.perturbation.rounds";
  private static final String PERTURBATION_SLEEP_MS_PROPERTY = "capella.test.migration.relation.perturbation.sleepMs";
  private static final String PAUSE_AT_PROPERTY = "capella.test.migration.relation.pauseAt";
  private static final String PAUSE_MS_PROPERTY = "capella.test.migration.relation.pauseMs";
  private static final String DATA_FILTER = System.getProperty(FILTER_PROPERTY, "").trim();
  private static final int DEFAULT_PERTURBATION_ROUNDS = 20;
  private static final long DEFAULT_PERTURBATION_SLEEP_MS = 3000L;
  private static final long DEFAULT_PAUSE_MS = 60000L;
  private static final Point COLLAPSED_START = new Point(58, 70);
  private static final Point COLLAPSED_END = new Point(300, 70);

  private enum PerturbationMode {
    NONE("none"), YIELD_ONLY("yield-only"), JOB_DRAIN("job-drain"), EDITOR_REOPEN("editor-reopen"), EXTRA_REFRESH(
        "extra-refresh");

    private final String propertyValue;

    PerturbationMode(String propertyValue) {
      this.propertyValue = propertyValue;
    }

    static PerturbationMode fromProperty(String value) {
      for (PerturbationMode mode : values()) {
        if (mode.propertyValue.equalsIgnoreCase(value)) {
          return mode;
        }
      }
      return NONE;
    }

    String propertyValue() {
      return propertyValue;
    }
  }

  private enum NavigableState {
    NONE_A2B_FIRST(false, false), NONE_B2A_FIRST(false, false), A2B(true, false), B2A(false, true), BOTH_A2B_FIRST(true,
        true), BOTH_B2A_FIRST(true, true);

    private boolean navigableAtoB;
    private boolean navigableBtoA;

    NavigableState(boolean a2bNavigable, boolean b2aNavigable) {
      this.navigableAtoB = a2bNavigable;
      this.navigableBtoA = b2aNavigable;
    }

    public boolean isNavigableAtoB() {
      return navigableAtoB;
    }

    public boolean isNavigableBtoA() {
      return navigableBtoA;
    }

    public boolean isNavigableOnlyAtoB() {
      return navigableAtoB && !navigableBtoA;
    }

    public boolean isNavigableOnlyBtoA() {
      return navigableBtoA && !navigableAtoB;
    }
  }

  private enum AbstractState {
    NONE, A2B, B2A, BOTH;

    public boolean isAbstractAtoB() {
      return this == A2B || this == BOTH;
    }

    public boolean isAbstractBtoA() {
      return this == B2A || this == BOTH;
    }
  }

  private record AssociationUiState(List<DDiagramElement> diagramElements, DDiagramElement classA, DDiagramElement classB,
      DEdge association, GraphicalEditPart associationEditPart, GraphicalEditPart beginLabelEditPart,
      GraphicalEditPart middleLabelEditPart, GraphicalEditPart endLabelEditPart, PointList bendPoints,
      Rectangle beginLabelBounds, int beginLabelStyle, Rectangle middleLabelBounds, Rectangle endLabelBounds,
      int endLabelStyle) {
  }

  private static final String CLASS_ID_A = "2a30d109-d64f-4aa4-81f0-3b16e023c542";
  private static final String CLASS_ID_B = "ca411035-9f42-471e-bcc4-2f139ef39f6f";

  private IProject project;
  private Session session;
  private SessionContext context;
  private CDBDiagram cdb;

  private final String filename;
  private final PointList bendPointsExpected;
  private final Rectangle beginLabelBoundsExpected;
  private final int beginLabelStyleExpected;
  private final Rectangle middleLabelBoundsExpected;
  private final Rectangle endLabelBoundsExpected;
  private final int endLabelStyleExpected;
  private final Optional<EdgeArrows> sourceEdgeArrowExpected;
  private final Optional<EdgeArrows> targetEdgeArrowExpected;

  private static EdgeArrows getBaseArrow(AggregationKind kind) {
    switch (kind) {
    case AGGREGATION:
      return EdgeArrows.DIAMOND_LITERAL;
    case COMPOSITION:
      return EdgeArrows.FILL_DIAMOND_LITERAL;
    default:
      return EdgeArrows.NO_DECORATION_LITERAL;
    }
  }

  private static EdgeArrows getArrowWithNavigability(EdgeArrows initial, boolean isNavigable) {
    if (!isNavigable) {
      return initial;
    }
    switch (initial) {
    case DIAMOND_LITERAL:
      return EdgeArrows.INPUT_ARROW_WITH_DIAMOND_LITERAL;
    case FILL_DIAMOND_LITERAL:
      return EdgeArrows.INPUT_ARROW_WITH_FILL_DIAMOND_LITERAL;
    default:
      return EdgeArrows.INPUT_ARROW_LITERAL;
    }
  }

  static String getTestFilename(AggregationKind kindAtoB, AggregationKind kindBtoA, NavigableState navigableState,
      AbstractState abstractState) {
    String kindAtoBstr = kindAtoB.toString().substring(0, 3).toLowerCase();
    String kindBtoAstr = kindBtoA.toString().substring(0, 3).toLowerCase();
    String kind = kindAtoBstr + "2" + kindBtoAstr;
    String navigable = "-NAV" + navigableState.toString().toLowerCase();
    String abs = "-ABS" + abstractState.toString().toLowerCase();
    return kind + navigable + abs;
  }

  static Collection<Object[]> getKindTestData() {
    return AggregationKind.VALUES.stream().flatMap(kindAtoB -> {
      return AggregationKind.VALUES.stream().map(kindBtoA -> {
        EdgeArrows sourceEdgeArrows;
        EdgeArrows targetEdgeArrows;
        if (kindAtoB.equals(AggregationKind.UNSET) || kindBtoA.equals(AggregationKind.UNSET)) {
          sourceEdgeArrows = getArrowWithNavigability(EdgeArrows.NO_DECORATION_LITERAL, false);
          targetEdgeArrows = getArrowWithNavigability(EdgeArrows.NO_DECORATION_LITERAL, true);
        } else if (!kindAtoB.equals(AggregationKind.ASSOCIATION) && !kindBtoA.equals(AggregationKind.ASSOCIATION)) {
          sourceEdgeArrows = EdgeArrows.NO_DECORATION_LITERAL;
          targetEdgeArrows = EdgeArrows.NO_DECORATION_LITERAL;
        } else {
          sourceEdgeArrows = getArrowWithNavigability(getBaseArrow(kindAtoB), false);
          targetEdgeArrows = getArrowWithNavigability(getBaseArrow(kindBtoA), true);
        }

        return new Object[] { getTestFilename(kindAtoB, kindBtoA, NavigableState.A2B, AbstractState.NONE),
            new PointList(new int[] { 58, 72, 120, 20, 170, 100, 260, 40, 300, 66 }),
            new Rectangle(103, 47, 0, 0), SWT.NORMAL, new Rectangle(140, 30, 94, 16),
            new Rectangle(250, 50, 6, 15), SWT.NORMAL, Optional.of(sourceEdgeArrows), Optional.of(targetEdgeArrows), };
      });
    }).toList();
  }

  static Collection<Object[]> getNavigableTestData() {
    return Arrays.stream(NavigableState.values()).filter(navigableState -> !navigableState.equals(NavigableState.A2B))
        .flatMap(navigableState -> {
          Rectangle beginLabelBounds;
          Rectangle endLabelBounds;
          if (navigableState.isNavigableOnlyAtoB()) {
            beginLabelBounds = new Rectangle(103, 47, 0, 0);
          } else {
            beginLabelBounds = new Rectangle(100, 40, 6, 15);
          }
          if (navigableState.isNavigableOnlyBtoA()) {
            endLabelBounds = new Rectangle(253, 57, 0, 0);
          } else {
            endLabelBounds = new Rectangle(250, 50, 6, 15);
          }

          return Stream.of(new AggregationKind[] { AggregationKind.ASSOCIATION, AggregationKind.ASSOCIATION },
              new AggregationKind[] { AggregationKind.ASSOCIATION, AggregationKind.AGGREGATION },
              new AggregationKind[] { AggregationKind.AGGREGATION, AggregationKind.ASSOCIATION },
              new AggregationKind[] { AggregationKind.ASSOCIATION, AggregationKind.COMPOSITION },
              new AggregationKind[] { AggregationKind.COMPOSITION, AggregationKind.ASSOCIATION }).map(kinds -> {
                AggregationKind kindAtoB = kinds[0];
                AggregationKind kindBtoA = kinds[1];

                EdgeArrows sourceEdgeArrows = getArrowWithNavigability(getBaseArrow(kindAtoB),
                    navigableState.isNavigableBtoA());
                EdgeArrows targetEdgeArrows = getArrowWithNavigability(getBaseArrow(kindBtoA),
                    navigableState.isNavigableAtoB());

                return new Object[] { getTestFilename(kindAtoB, kindBtoA, navigableState, AbstractState.NONE),
                    new PointList(new int[] { 58, 72, 120, 20, 170, 100, 260, 40, 300, 66 }), beginLabelBounds,
                    SWT.NORMAL, new Rectangle(140, 30, 94, 16), endLabelBounds, SWT.NORMAL,
                    Optional.of(sourceEdgeArrows), Optional.of(targetEdgeArrows), };
              });
        }).toList();
  }

  static Collection<Object[]> getAbstractTestData() {
    return Stream.of(AbstractState.A2B, AbstractState.B2A, AbstractState.BOTH).flatMap(abstractState -> {
      return Arrays.stream(NavigableState.values()).map(navigableState -> {
        Rectangle beginLabelBounds;
        Rectangle endLabelBounds;
        if (navigableState.isNavigableOnlyAtoB()) {
          beginLabelBounds = new Rectangle(103, 47, 0, 0);
        } else {
          beginLabelBounds = new Rectangle(100, 40, 6, 15);
        }
        if (navigableState.isNavigableOnlyBtoA()) {
          endLabelBounds = new Rectangle(253, 57, 0, 0);
        } else {
          endLabelBounds = new Rectangle(250, 50, 6, 15);
        }

        EdgeArrows sourceEdgeArrows = getArrowWithNavigability(EdgeArrows.NO_DECORATION_LITERAL,
            navigableState.isNavigableBtoA());
        EdgeArrows targetEdgeArrows = getArrowWithNavigability(EdgeArrows.NO_DECORATION_LITERAL,
            navigableState.isNavigableAtoB());

        int beginLabelStyle;
        int endLabelStyle;
        if (abstractState.isAbstractBtoA()) {
          beginLabelStyle = SWT.ITALIC;
        } else {
          beginLabelStyle = SWT.NORMAL;
        }
        if (abstractState.isAbstractAtoB()) {
          endLabelStyle = SWT.ITALIC;
        } else {
          endLabelStyle = SWT.NORMAL;
        }

        return new Object[] { getTestFilename(AggregationKind.ASSOCIATION, AggregationKind.ASSOCIATION, navigableState,
            abstractState), new PointList(new int[] { 58, 72, 120, 20, 170, 100, 260, 40, 300, 66 }),
            beginLabelBounds, beginLabelStyle, new Rectangle(140, 30, 94, 16), endLabelBounds, endLabelStyle,
            Optional.of(sourceEdgeArrows), Optional.of(targetEdgeArrows), };
      });
    }).toList();
  }

  @Parameters(name = "{0}")
  public static Collection<Object[]> data() {
    List<Object[]> allTest = new ArrayList<>();
    allTest.addAll(getKindTestData());
    allTest.addAll(getNavigableTestData());
    allTest.addAll(getAbstractTestData());
    if (!DATA_FILTER.isEmpty()) {
      List<Object[]> filtered = allTest.stream()
          .filter(testData -> testData[0] instanceof String name && (name.equals(DATA_FILTER) || name.contains(DATA_FILTER)))
          .toList();
      if (filtered.isEmpty()) {
        throw new IllegalArgumentException(
            "No RelationStability testcase matches " + FILTER_PROPERTY + "=" + DATA_FILTER);
      }
      return filtered;
    }
    return allTest;
  }

  public RelationStability(String filename, PointList bendPoints, Rectangle beginLabelBounds, int beginLabelStyle,
      Rectangle middleLabelBounds, Rectangle endLabelBounds, int endLabelStyle, Optional<EdgeArrows> sourceEdgeArrow,
      Optional<EdgeArrows> targetEdgeArrow) {
    this.filename = filename;
    this.bendPointsExpected = bendPoints;
    this.beginLabelBoundsExpected = beginLabelBounds;
    this.beginLabelStyleExpected = beginLabelStyle;
    this.middleLabelBoundsExpected = middleLabelBounds;
    this.endLabelBoundsExpected = endLabelBounds;
    this.endLabelStyleExpected = endLabelStyle;
    this.sourceEdgeArrowExpected = sourceEdgeArrow;
    this.targetEdgeArrowExpected = targetEdgeArrow;
  }

  @Override
  protected String getRelativeModelsFolderName() {
    return super.getRelativeModelsFolderName() + "/doremi-4873-datatest";
  }

  @Override
  protected String getRequiredTestModel() {
    return filename;
  }

  @Before
  @Override
  public void setUp() throws Exception {
    super.setUp();
    project = IResourceHelpers.getEclipseProjectInWorkspace(getRequiredTestModel());
  }

  @After
  @Override
  public void tearDown() throws Exception {
    super.tearDown();
  }

  private static boolean isTraceEnabled() {
    return Boolean.getBoolean(TRACE_PROPERTY) || getPerturbationMode() != PerturbationMode.NONE;
  }

  private static PerturbationMode getPerturbationMode() {
    return PerturbationMode.fromProperty(System.getProperty(PERTURBATION_PROPERTY, PerturbationMode.NONE.propertyValue()));
  }

  private static int getPerturbationRounds() {
    return getIntProperty(PERTURBATION_ROUNDS_PROPERTY, DEFAULT_PERTURBATION_ROUNDS);
  }

  private static long getPerturbationSleepMs() {
    return getLongProperty(PERTURBATION_SLEEP_MS_PROPERTY, DEFAULT_PERTURBATION_SLEEP_MS);
  }

  private static String getPauseCheckpoint() {
    return System.getProperty(PAUSE_AT_PROPERTY, "none").trim();
  }

  private static long getPauseDurationMs() {
    return getLongProperty(PAUSE_MS_PROPERTY, DEFAULT_PAUSE_MS);
  }

  private static int getIntProperty(String propertyName, int defaultValue) {
    String raw = System.getProperty(propertyName);
    if (raw == null || raw.isBlank()) {
      return defaultValue;
    }
    try {
      return Integer.parseInt(raw.trim());
    } catch (NumberFormatException e) {
      return defaultValue;
    }
  }

  private static long getLongProperty(String propertyName, long defaultValue) {
    String raw = System.getProperty(propertyName);
    if (raw == null || raw.isBlank()) {
      return defaultValue;
    }
    try {
      return Long.parseLong(raw.trim());
    } catch (NumberFormatException e) {
      return defaultValue;
    }
  }

  private static void trace(String message) {
    System.out.println("[RELDBG] " + message);
    System.out.flush();
  }

  private void logRevisionBanner() {
    trace("revision=" + DEBUG_REVISION + " testcase=" + filename + " filter=" + DATA_FILTER + " trace="
        + Boolean.getBoolean(TRACE_PROPERTY) + " perturbation=" + getPerturbationMode().propertyValue() + " rounds="
        + getPerturbationRounds() + " sleepMs=" + getPerturbationSleepMs() + " pauseAt=" + getPauseCheckpoint()
        + " helperRevision=" + MigrationHelper.DEBUG_REVISION);
  }

  private void pauseIfRequested(String checkpoint) throws InterruptedException {
    if (!checkpoint.equalsIgnoreCase(getPauseCheckpoint())) {
      return;
    }
    trace("pause checkpoint=" + checkpoint + " revision=" + DEBUG_REVISION + " sleepMs=" + getPauseDurationMs());
    Thread.sleep(getPauseDurationMs());
  }

  private String pointsToString(PointList points) {
    if (points == null) {
      return "MISSING";
    }
    ArrayList<String> pointsArrayList = new ArrayList<>();
    for (int i = 0; i < points.size(); ++i) {
      pointsArrayList.add("(" + points.getPoint(i).x + ", " + points.getPoint(i).y + ")");
    }
    return "{" + String.join(", ", pointsArrayList) + "}";
  }

  private boolean pointsEqual(PointList expected, PointList actual) {
    int len = expected.size();
    if (len != actual.size()) {
      return false;
    }
    for (int i = 0; i < len; ++i) {
      if (!expected.getPoint(i).equals(actual.getPoint(i))) {
        return false;
      }
    }
    return true;
  }

  private void assertPointsEquals(String message, PointList expected, PointList actual) {
    if (!pointsEqual(expected, actual)) {
      failNotEquals(message, pointsToString(expected), pointsToString(actual));
    }
  }

  private void assertLabelBoundsEquals(String message, Rectangle expected, Rectangle actual) {
    final double positionDelta = 1.;
    final double widthDelta = 16.;
    final double heightDelta = 4.;

    final boolean sameCenter;
    final boolean sameSize;

    Point expectedCenter = expected.getCenter();
    Point actualCenter = actual.getCenter();
    Dimension expectedSize = expected.getSize();
    Dimension actualSize = actual.getSize();

    Dimension centerDiff = actualCenter.getDifference(expectedCenter);
    sameCenter = Math.abs(centerDiff.preciseWidth()) < positionDelta
        && Math.abs(centerDiff.preciseHeight()) < positionDelta;
    if (expectedSize.isEmpty()) {
      sameSize = actualSize.isEmpty();
    } else {
      Dimension sizeDiff = actualSize.getShrinked(expectedSize);
      sameSize = Math.abs(sizeDiff.preciseWidth()) < widthDelta && Math.abs(sizeDiff.preciseHeight()) < heightDelta;
    }

    if (!sameCenter || !sameSize) {
      failNotEquals(message, expected, actual);
    }
  }

  private boolean isClassA(DDiagramElement diagramElement) {
    return diagramElement.getTarget() instanceof Classifier classifier && CLASS_ID_A.equals(classifier.getId());
  }

  private boolean isClassB(DDiagramElement diagramElement) {
    return diagramElement.getTarget() instanceof Classifier classifier && CLASS_ID_B.equals(classifier.getId());
  }

  private boolean isAssociation(DDiagramElement diagramElement) {
    return diagramElement.getTarget() instanceof Association;
  }

  private Supplier<AssertionFailedError> getFailLambda(String message) {
    return () -> new AssertionFailedError(message);
  }

  private DDiagram getModelDiagram() {
    Object representation = DiagramHelper.getDRepresentation(session, DIAGRAM_NAME);
    if (!(representation instanceof DDiagram diagram)) {
      throw new AssertionFailedError("The " + DIAGRAM_NAME + " diagram was not found after the migration");
    }
    return diagram;
  }

  private DDiagramElement findClassA(List<DDiagramElement> diagramElements, String checkpoint) {
    return diagramElements.stream().filter(this::isClassA).findFirst()
        .orElseThrow(getFailLambda("The class A was not found on the diagram after the migration at " + checkpoint));
  }

  private DDiagramElement findClassB(List<DDiagramElement> diagramElements, String checkpoint) {
    return diagramElements.stream().filter(this::isClassB).findFirst()
        .orElseThrow(getFailLambda("The class B was not found on the diagram after the migration at " + checkpoint));
  }

  private DEdge findAssociation(List<DDiagramElement> diagramElements, String checkpoint) {
    return diagramElements.stream().filter(this::isAssociation).filter(DEdge.class::isInstance).map(DEdge.class::cast)
        .findFirst()
        .orElseThrow(getFailLambda("The association was not found on the diagram after the migration at " + checkpoint));
  }

  private AssociationUiState captureUiState(String checkpoint) {
    List<DDiagramElement> diagramElements = new ArrayList<>(cdb.getDiagram().getOwnedDiagramElements());
    DDiagramElement classA = findClassA(diagramElements, checkpoint);
    DDiagramElement classB = findClassB(diagramElements, checkpoint);
    DEdge association = findAssociation(diagramElements, checkpoint);
    GraphicalEditPart associationEditPart = (GraphicalEditPart) DiagramServices.getDiagramServices().getEditPart(association);
    if (associationEditPart == null) {
      throw new AssertionFailedError("The association edit part was not found after the migration at " + checkpoint);
    }
    GraphicalEditPart beginLabelEditPart = associationEditPart.getChildren().stream()
        .filter(DEdgeBeginNameEditPart.class::isInstance).map(GraphicalEditPart.class::cast).findFirst().orElseThrow(
            getFailLambda("The association begin label was not found after the migration at " + checkpoint));
    GraphicalEditPart middleLabelEditPart = associationEditPart.getChildren().stream()
        .filter(DEdgeNameEditPart.class::isInstance).map(GraphicalEditPart.class::cast).findFirst().orElseThrow(
            getFailLambda("The association middle label was not found after the migration at " + checkpoint));
    GraphicalEditPart endLabelEditPart = associationEditPart.getChildren().stream()
        .filter(DEdgeEndNameEditPart.class::isInstance).map(GraphicalEditPart.class::cast).findFirst().orElseThrow(
            getFailLambda("The association end label was not found after the migration at " + checkpoint));

    return new AssociationUiState(diagramElements, classA, classB, association, associationEditPart, beginLabelEditPart,
        middleLabelEditPart, endLabelEditPart, ((Connection) associationEditPart.getFigure()).getPoints().getCopy(),
        beginLabelEditPart.getFigure().getBounds().getCopy(),
        beginLabelEditPart.getFigure().getFont().getFontData()[0].getStyle(),
        middleLabelEditPart.getFigure().getBounds().getCopy(), endLabelEditPart.getFigure().getBounds().getCopy(),
        endLabelEditPart.getFigure().getFont().getFontData()[0].getStyle());
  }

  private void assertAssociationModel(AssociationUiState uiState) {
    assertEquals("The number of diagram element after migration is wrong", 3, uiState.diagramElements().size());
    assertEquals("The association source node after migration is wrong", uiState.classA(), uiState.association().getSourceNode());
    assertEquals("The association target node after migration is wrong", uiState.classB(), uiState.association().getTargetNode());

    sourceEdgeArrowExpected.ifPresent(edgeArrowExpected -> {
      assertEquals("Wrong association source arrow", edgeArrowExpected, uiState.association().getOwnedStyle().getSourceArrow());
    });
    targetEdgeArrowExpected.ifPresent(edgeArrowExpected -> {
      assertEquals("Wrong association target arrow", edgeArrowExpected, uiState.association().getOwnedStyle().getTargetArrow());
    });
  }

  private String rectangleToString(Rectangle rectangle) {
    return rectangle == null ? "MISSING" : rectangle.toString();
  }

  private String routingStyleToString(DEdge association) {
    if (association == null || association.getOwnedStyle() == null || association.getOwnedStyle().getRoutingStyle() == null) {
      return "MISSING";
    }
    return association.getOwnedStyle().getRoutingStyle().getLiteral();
  }

  private String gmfBendpointsToString(DEdge association) {
    if (association == null) {
      return "MISSING";
    }
    Edge gmfEdge = SiriusGMFHelper.getGmfEdge(association);
    if (gmfEdge == null) {
      return "MISSING";
    }
    Bendpoints bendpoints = gmfEdge.getBendpoints();
    if (bendpoints instanceof RelativeBendpoints relativeBendpoints) {
      return relativeBendpoints.getPoints().toString();
    }
    return bendpoints == null ? "MISSING" : bendpoints.toString();
  }

  private String classifyFigureRoute(PointList points) {
    if (points == null) {
      return "missing";
    }
    if (pointsEqual(bendPointsExpected, points)) {
      return "expected";
    }
    if (isCollapsedStraightRoute(points)) {
      return "collapsed-straight";
    }
    return "other";
  }

  private boolean isCollapsedStraightRoute(PointList points) {
    return points != null && points.size() == 2 && COLLAPSED_START.equals(points.getPoint(0))
        && COLLAPSED_END.equals(points.getPoint(1));
  }

  private void logModelSnapshot(String checkpoint, DEdge association) {
    if (!isTraceEnabled()) {
      return;
    }
    trace("checkpoint=" + checkpoint + " revision=" + DEBUG_REVISION + " testcase=" + filename + " modelRouting="
        + routingStyleToString(association) + " sourceArrow="
        + (association == null || association.getOwnedStyle() == null ? "MISSING" : association.getOwnedStyle().getSourceArrow())
        + " targetArrow="
        + (association == null || association.getOwnedStyle() == null ? "MISSING" : association.getOwnedStyle().getTargetArrow())
        + " gmfBendpoints=" + gmfBendpointsToString(association) + " relevantJobs="
        + MigrationHelper.describeRelevantAsyncJobs());
  }

  private void logUiSnapshot(String checkpoint, AssociationUiState uiState) {
    if (!isTraceEnabled()) {
      return;
    }
    trace("checkpoint=" + checkpoint + " revision=" + DEBUG_REVISION + " testcase=" + filename + " figureRoute="
        + pointsToString(uiState.bendPoints()) + " figureState=" + classifyFigureRoute(uiState.bendPoints())
        + " beginLabel=" + rectangleToString(uiState.beginLabelBounds()) + " middleLabel="
        + rectangleToString(uiState.middleLabelBounds()) + " endLabel=" + rectangleToString(uiState.endLabelBounds())
        + " beginStyle=" + uiState.beginLabelStyle() + " endStyle=" + uiState.endLabelStyle() + " modelRouting="
        + routingStyleToString(uiState.association()) + " gmfBendpoints=" + gmfBendpointsToString(uiState.association())
        + " relevantJobs=" + MigrationHelper.describeRelevantAsyncJobs());
  }

  private AssociationUiState runPerturbationRound(PerturbationMode mode, int round) throws Exception {
    long sleepMs = getPerturbationSleepMs();
    switch (mode) {
    case YIELD_ONLY:
      Thread.sleep(sleepMs);
      GuiActions.flushASyncGuiThread();
      break;
    case JOB_DRAIN:
      GuiActions.flushASyncGuiJobs();
      Thread.sleep(sleepMs);
      GuiActions.flushASyncGuiThread();
      break;
    case EDITOR_REOPEN:
      cdb.close();
      GuiActions.flushASyncGuiJobs();
      Thread.sleep(sleepMs);
      cdb = CDBDiagram.openDiagram(context, DIAGRAM_NAME);
      GuiActions.flushASyncGuiThread();
      break;
    case EXTRA_REFRESH:
      cdb.refreshDiagram();
      GuiActions.flushASyncGuiJobs();
      Thread.sleep(sleepMs);
      GuiActions.flushASyncGuiThread();
      break;
    case NONE:
    default:
      return captureUiState("perturbation-round-" + round + "-none");
    }

    AssociationUiState uiState = captureUiState("perturbation-round-" + round);
    logUiSnapshot("perturbation-round-" + round, uiState);
    return uiState;
  }

  private AssociationUiState reproduceIfRequested(AssociationUiState initialState) throws Exception {
    PerturbationMode mode = getPerturbationMode();
    if (mode == PerturbationMode.NONE) {
      return initialState;
    }

    trace("perturbation-start revision=" + DEBUG_REVISION + " testcase=" + filename + " mode=" + mode.propertyValue()
        + " rounds=" + getPerturbationRounds() + " sleepMs=" + getPerturbationSleepMs());
    AssociationUiState currentState = initialState;
    for (int round = 1; round <= getPerturbationRounds(); round++) {
      currentState = runPerturbationRound(mode, round);
      if (isCollapsedStraightRoute(currentState.bendPoints())) {
        fail("Perturbation mode " + mode.propertyValue() + " reproduced the collapsed relation route at round " + round
            + " for " + filename + ". See [RELDBG] checkpoints for the first divergent state.");
      }
    }

    fail("Perturbation mode " + mode.propertyValue() + " did not reproduce the collapsed relation route after "
        + getPerturbationRounds() + " rounds for " + filename + ".");
    return currentState;
  }

  @Test
  @Override
  public void test() throws Exception {
    logRevisionBanner();
    pauseIfRequested("before-migrate");

    MigrationHelper.migrateProject(project);
    pauseIfRequested("after-migrate");

    session = getSession(getRequiredTestModel());
    context = new SessionContext(session);
    DDiagram modelDiagram = getModelDiagram();
    DEdge modelAssociation = findAssociation(new ArrayList<>(modelDiagram.getOwnedDiagramElements()), "after-migration");
    logModelSnapshot("after-migration", modelAssociation);

    cdb = CDBDiagram.openDiagram(context, DIAGRAM_NAME);
    GuiActions.flushASyncGuiThread();
    pauseIfRequested("after-open");

    AssociationUiState uiState = captureUiState("after-open");
    assertAssociationModel(uiState);
    logUiSnapshot("after-open", uiState);
    pauseIfRequested("after-editpart");

    uiState = reproduceIfRequested(uiState);
    logUiSnapshot("before-assert", uiState);
    pauseIfRequested("before-assert");

    assertPointsEquals("Wrong bendpoints after migration:", bendPointsExpected, uiState.bendPoints());
    assertLabelBoundsEquals("Wrong begin label bounds after migration:", beginLabelBoundsExpected, uiState.beginLabelBounds());
    assertLabelBoundsEquals("Wrong middle label bounds after migration:", middleLabelBoundsExpected,
        uiState.middleLabelBounds());
    assertLabelBoundsEquals("Wrong end label bounds after migration:", endLabelBoundsExpected, uiState.endLabelBounds());
    assertEquals("Wrong begin label style after migration", beginLabelStyleExpected, uiState.beginLabelStyle());
    assertEquals("Wrong end label style after migration", endLabelStyleExpected, uiState.endLabelStyle());
  }
}
