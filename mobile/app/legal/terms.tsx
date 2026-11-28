import { LegalView } from '../../src/components/LegalView';
import { TERMS } from '../../src/domain/legal';

export default function Terms() {
  return <LegalView sections={TERMS} />;
}
